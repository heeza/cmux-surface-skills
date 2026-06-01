# cmux → 정교한 Orchestrator 진화 제안

> 출처: `cmux_cross surface:6(agy)` 3-round Self-Refinement + 코드베이스(`cmux-v5-lib.sh`, 1319 LoC) 정적 분석 합성.
> 현재 정체성: **A2A 단발 메신저**(per-job FIFO 응답 채널 + prompt 주입 + llm/worker auto-detect).
> 목표 정체성: **상태를 가진 작업 오케스트레이터**(의존성 인지 스케줄링 + 실패 복구 + 관측가능).

---

## 0. 현 위치 진단 (왜 아직 orchestrator가 아닌가)

| 영역 | 현재 | 한계 |
|---|---|---|
| 실행 모델 | `cmux_ask`(동기) / `cmux_send`+`cmux_collect`(비동기 1-shot) | 작업 간 **의존성 표현 불가**. fan-out은 `cmux_broadcast`, 다회전은 `cmux_cross`로 분리돼 조합 불가 |
| 상태 | FIFO 파일 존재 여부가 곧 상태 (`/tmp/cmux-fifo/*.res`) | 명시적 **job 레지스트리/상태머신 부재**. PENDING/RUNNING/DONE/FAILED 구분 없음 |
| 실패 처리 | `RC=124`(timeout) 반환 후 종료. `cmux_cross`는 라운드 중 실패 시 `return $?`로 **전체 중단** | 재시도·부분복구·체크포인트 없음 |
| 라우팅 | 호출자가 surface ref를 하드코딩하거나 "첫 llm" 자동탐색 | **부하/능력 기반 선택 없음**. 바쁜 sidecar에도 그대로 주입 |
| 관측 | stderr 1줄 (`surface:6 (llm) 25s 62B ok`) | 구조화 로그·메트릭·타임라인 없음. 사후 디버깅 불가 |

**즉시 고칠 버그 (이번 실행에서 실제 발견):**
`cmux_cross <target> <prompt> --rounds N`에서 analyzer 생략 시 파서가 prompt를 analyzer로 오인 → `unknown arg: N`으로 죽음.
원인: `if [[ "$1" != -* ]] && [ $# -ge 2 ]` 가 **다음 토큰이 `--`옵션인지 검사하지 않음**.
수정: `[[ "$1" != -* ]] && [[ "${2:-}" != -* ]] && [ $# -ge 2 ]` (다음 토큰도 비옵션일 때만 analyzer로 간주).

---

## 1. 우선순위 로드맵

agy가 수렴한 "내부 견고성"(취소 전파·포터블 락·PTY 유휴 감지)은 **P0의 토대**다.
그 위에 orchestrator 4대 축을 쌓는다.

### P0 — 견고성 기반 (orchestrator의 전제조건)
agy 제안 + 코드 분석. 이게 안 되면 상위 기능이 전부 불안정.

1. **포터블 상태 락**: 현재 `mkdir -p`(idempotent, 락 아님)뿐. `mkdir <dir>`(원자적 실패) 기반 락 + PID/TTL 검증으로 stale lock 자동 복구. job 레지스트리 동시쓰기 보호용 전제.
2. **취소 전파 루프화**: `cmux_cross` 중단 시 진행 중 하위 job들이 좀비로 남음. `cmux_cancel`을 **DAG 후손까지 재귀 전파**.
3. **sidecar 생존성 정밀화**: `_cmux_v5_detect`의 프로세스 화이트리스트에 더해 **PTY 유휴/좀비 판정**(휴면 sidecar에 주입 → 124 timeout 방지).
4. **주입 truncation 캡**: 라운드 누적으로 prompt가 무한 증식. 이미 `CROSS_RESPONSE_MAX`는 있으나 **주입 직전 hard cap + 경고 로그** 추가.

### P1 — 상태머신 + Job 레지스트리 (orchestrator의 심장)
FIFO-as-state를 **명시적 job 레코드**로 승격.

```
/tmp/cmux-jobs/<jobid>/
  meta.json      # {id, target, prompt_hash, deps:[], state, attempts, created, deadline}
  state          # PENDING|DISPATCHING|RUNNING|DONE|FAILED|CANCELLED
  result         # FIFO에서 수확한 본문
  events.ndjson  # 상태 전이 타임라인
```
- 상태 전이: `PENDING→DISPATCHING`(선점 마킹, agy의 "중복 전송 방지")→`RUNNING`(주입 완료)→`DONE|FAILED`.
- `cmux_check`/`cmux_collect`가 이 레코드를 읽도록 전환 → 크래시 후 재개 가능.

### P2 — DAG 스케줄러 (`cmux_flow`)
신규 진입점. 작업 그래프를 선언하면 의존성 위상정렬 후 **준비된 노드만 fan-out**, 완료 시 후속 해금.

```bash
cmux_flow <<'YAML'
nodes:
  a: { target: surface:6, prompt: "스키마 초안" }
  b: { target: surface:2, prompt: "a 기반 마이그레이션", deps: [a] }
  c: { target: surface:1, prompt: "a 기반 테스트",      deps: [a] }
  d: { target: agy,       prompt: "b,c 리뷰 종합",      deps: [b, c] }
YAML
```
- b·c는 a 완료 후 **병렬** 실행(기존 `cmux_broadcast` 재사용), d는 둘 다 완료 시 실행.
- 노드 결과를 후속 prompt에 `{{a.result}}` 템플릿으로 주입 → `cmux_cross`의 라운드 임베딩을 일반화.
- 실패 노드는 그래프에서 격리, 독립 분기는 계속 진행(`cmux_cross`의 all-or-nothing 탈피).

### P3 — 라우팅 / 로드밸런싱
호출자가 surface를 고르지 않고 **능력·부하로 선택**.

- **capability 태그**: surface 메타에 `{kind: codex|claude|gemini|agy, busy: bool}`. `target: "@coding"` 같은 논리 라우팅.
- **부하 회피**: P1 레지스트리에서 해당 surface의 RUNNING job 수 조회 → 가장 한가한 동급 surface로 분배. P0-3의 유휴 판정 재사용.
- **재시도 라우팅**: FAILED 시 같은 능력군의 **다른** surface로 재배치(backoff).

### P4 — 관측가능성
- **구조화 이벤트**: `events.ndjson`을 표준화(`{ts, job, from, to, bytes, rc}`). 기존 stderr 1줄은 사람용 요약으로 유지.
- **`cmux_trace <flow>`**: job 레코드를 위상순 타임라인/간트로 렌더(누가 누구를 몇 초 기다렸는지).
- **메트릭**: per-surface p50/p95 응답시간, 성공률, timeout율 → P3 라우팅 입력으로 환류.

---

## 2. 설계 원칙 (회귀 방지)

1. **하위호환**: `cmux_ask`/`send`/`collect` 시그니처 불변. 신규는 `cmux_flow`/`cmux_trace`로 추가, 내부에서 기존 함수 재사용.
2. **상태는 파일, 로직은 멱등**: 모든 전이는 재실행 안전. 크래시=중단점, 재개=레코드 재로드.
3. **cap 규율 유지**: DAG/라우팅이 토큰을 폭증시키지 않도록 노드별 response-max·flow 전역 예산 캡.
4. **agy 견고성을 토대로**: P1+ 모든 동시성은 P0 락/취소/유휴판정 위에서만 동작.

---

## 3. 다음 액션 (착수 순서)

1. `cmux_cross` arg 파싱 버그 핫픽스 (1줄, 즉시).
2. P0-1 포터블 락 헬퍼 `_cmux_v5_lock`/`_unlock` 추가 + 기존 GC에 stale-lock 정리 편입.
3. P1 job 레코드 디렉터리 스킴 + `cmux_collect`/`check`를 레코드 기반으로 리팩터(FIFO는 전송 채널로만 강등).
4. P2 `cmux_flow` MVP: 위상정렬 + 준비노드 broadcast + 결과 템플릿 주입.
5. P4 `events.ndjson` + `cmux_trace`로 P2를 가시화한 뒤 P3 라우팅 착수.

---

## 4. 구현 현황 (이 브랜치 `fix/cmux-orchestrator-p0`)

전 단계 구현 완료. 모든 변경은 **추가형**이며 기존 public 함수
(`cmux_ask`/`send`/`collect`/`check`/`cross`/`broadcast`)와 FIFO 동작은 불변.
bash·zsh 양쪽에서 `-n` 및 기능 테스트 통과.

| 단계 | 상태 | 핵심 산출물 |
|---|---|---|
| cross 버그 핫픽스 | ✅ | `cmux_cross --rounds` 인자 파싱 수정 |
| P0-1 포터블 락 | ✅ | `_cmux_v5_lock`/`_unlock` (mkdir mutex, dead-pid 우선 stale, GC 백스톱) |
| P1 Job 레지스트리 | ✅ | `_cmux_v5_job_*` — `/tmp/cmux-jobs/<id>/{meta,state,result,events.ndjson}` 상태머신, 전 변이 락-가드 + temp+mv 원자교체 |
| P2 DAG 스케줄러 | ✅ | `cmux_flow` — TAB DSL, 위상정렬, 병렬 wave, `{{id.result}}` 템플릿, 실패 격리, cycle/unknown 거부 |
| P3 라우팅/LB | ✅ | `_cmux_v5_route`/`route_retry` — `@cap` 셀렉터 → 최소 busy surface, retry 제외, flow `@cap` 훅(`routed_to`). **wave 내 라우팅은 전역 `cmux-route` 락으로 직렬화**해 동시 fan-out 도 분산 |
| P4 관측가능성 | ✅ | `cmux_trace`(노드별 WAIT/EXEC/TOTAL + ASCII gantt), `cmux_metrics`(surface별 성공률·p50/p95) |

### 신규 public 함수
`cmux_flow`, `cmux_trace`, `cmux_metrics`. (그 외는 모두 `_cmux_v5_*` private.)

### 알려진 한계 / 후속 과제
- **percentile 정밀도**: 정수 초 단위 exec 시간 기반. 더 세밀하면 `events.ndjson` 에 ms 도입 필요(현재 `date +%s`, `%N` 회피).
- **선재 이슈**: 기존 `_cmux_v5_job` 의 `date +%s%N` 는 macOS 에서 `%N` 미지원(리터럴 `N`). 이번 범위 밖, 별도 추적.
- **cmux_flow ↔ 라이브 surface**: 테스트는 `_cmux_v5_flow_run_node` 스텁으로 DAG/라우팅/관측 로직만 검증. 실제 surface 연동 E2E 는 별도.
- **template 교차 주입**: dep result 가 다른 dep 의 `{{id}}` 토큰을 문자 그대로 포함하면 순차 치환 중 재주입 가능(실사용 드묾, 문서화된 한계).
