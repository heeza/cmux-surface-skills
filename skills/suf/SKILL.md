---
name: suf
description: cmux sidecar 와 마커 + read-screen 폴링으로 통신하는 agent-to-agent 프로토콜. 옆 패널의 Claude/Codex/agy/shell 에 메시지를 보내고 결과를 받아오기. "/suf", "옆 surface 에 물어봐", "sidecar 와 통신" 트리거. surface 생성 자체는 cmux 스킬, 그 위의 통신 사이클(send → poll → extract)이 suf.
---

# suf — agent ↔ agent 통신

## 한 사이클 (v3)

```
say → poll-extract → grace → re-extract
```

`suf_ask` 한 줄이 모두 포함. 분리 호출 안 함.

- **say**: `cmux send` + `send-key Enter` 로 본문 + 마커 송신.
- **poll-extract**: `read-screen --scrollback --lines 8000` 으로 surface buffer 전체를 dump 받아 **닫힌 ANSWER..END pair ≥ 2** 면 마지막 pair 반환 (0.5초 폴링).
- **grace**: sidecar 가 마커 닫고 추가 출력 중일 수 있어 0.5초 대기 후 한 번 더 추출.

surface 가 새로 필요하면 앞에 `cmux new-split`, 부모가 만든 sidecar 면 마지막에 `cmux close-surface`.

## 왜 polling 인가 (그리고 왜 pipe-pane 이 안 되는가)

검토했지만 채택 안 한 채널:

| 채널 | 왜 안 쓰는가 |
|---|---|
| `cmux pipe-pane --command` | terminal stdout stream 만 받음. Claude/Codex 같은 **TUI 는 chat history 를 ANSI cursor-rewrite 로 그리므로 stream 우회**. 1239줄 캡처돼도 마커 0회 잡힘. |
| `cmux wait-for -S <name>` | sidecar 가 답변 후 별도 signal 명령을 호출 안 하면 영원히 블록. LLM 누락 위험. |
| `cmux events --name <output>` | surface scrollback 변화 자체에 대한 event 발행 없음. agent hook/feed 위주, payload redacted. |

`read-screen` 은 surface 의 **rendered buffer** 를 dump 받기 때문에 cursor-rewrite 결과까지 보임. 유일하게 TUI 호환.

## 송수신 종단의 pair 카운팅

`cmux send` 후 prompt 가 surface 의 입력 chip 영역에 표시되는데, 거기에 마커 + placeholder `(여기에 답변 본문)` 까지 그대로 echo 된다. 즉:
- **send 직후**: closed pair 1개 (echo, body = placeholder)
- **sidecar 응답 완료**: closed pair 2개 (echo + 진짜 답변)

`suf_ask` 는 `pairs ≥ 2` 가 되면 **마지막 pair** 반환. echo 가 첫 번째라 자동으로 진짜 답변이 추출됨.

## 마커

`<<<SUF_ANSWER:$JOB>>>` ... `<<<SUF_END:$JOB>>>`

JOB = `nanosecond timestamp - PID - urandom4hex` — 동시 호출 / 같은 ns 충돌 방지 (v3 에서 random hex 추가).

## 권장 사용 — 헬퍼 한 줄

```bash
source ~/.agents/skills/suf/scripts/suf-lib.sh
ANSWER=$(suf_ask surface:22 "현황 보고")
```

| 함수 | 역할 |
|---|---|
| `suf_ask <surface> <prompt> [timeout]` | **say + poll + extract 한 번에**. 99% 이것만. |
| `suf_say <surface> <prompt>` | 송신만, JOB 반환 (fire-and-forget) |
| `suf_wait <surface> <job> [timeout]` | 닫힌 pair ≥ 2 까지 폴링 |
| `suf_hear <surface> <job>` | 즉시 추출 (대기 없음) |
| `suf_other_surfaces` | self 가 속한 워크스페이스의 다른 surface 목록 |

환경변수:
- `SUF_POLL_INTERVAL` (기본 0.5초) — 폴링 주기
- `SUF_GRACE` (기본 0.5초) — wait 성공 후 extract 전 안정화 대기
- `SUF_READ_LINES` (기본 8000) — read-screen scrollback 라인 수. 응답이 더 길면 늘리기.

인라인으로 직접 짤 일이 생기면, sidecar 프롬프트는 다음 골격을 따른다:

```
<USER_TASK>

답변은 반드시 아래 두 마커 사이에만 작성:
<<<SUF_ANSWER:$JOB>>>
(답변 본문)
<<<SUF_END:$JOB>>>
```

별도 ack 명령 불필요 — sidecar 가 마커 사이에 답만 쓰면 끝.

## v1 → v3 개선점 요약

| 항목 | v1 | v3 |
|---|---|---|
| 매칭 모델 | END 마커 횟수 ≥ 2 (열려있는 END 도 카운트) | **닫힌 ANSWER..END pair ≥ 2** (echo placeholder 자동 제외) |
| scrollback 한계 | 4000줄 | 8000줄 (`SUF_READ_LINES` 로 조정) |
| polling 주기 | 1초 | 0.5초 |
| job 충돌 | `ns-PID` (같은 ns 동시 호출 충돌) | `ns-PID-urandom4hex` |
| 추출 단위 함수 | `suf_hear` 별도 호출 | `_suf_try_extract` 내부 공유 |

## 함정

- **send-key Enter 누락** — 입력만 들어가고 실행 안 됨. `suf_say` 가 자동 처리.
- **self 에게 send** — 데드락. `suf_other_surfaces` / `$CMUX_SURFACE_ID` 로 self 배제. 같은 함수가 **다른 워크스페이스의 surface 도 자동 제외**한다.
- **사용자 surface 를 close** — 금지. 부모가 만든 sidecar 만 정리.
- **sidecar 가 마커 빠뜨림** — closed pair 1개 (echo) 에서 멈춰 timeout. 프롬프트에 마커 사용 지시가 명확해야 함.
- **응답 매우 길어 scrollback 밖으로 밀림** — `SUF_READ_LINES=20000` 식으로 늘리거나, 답변을 파일로 받기 (sidecar 가 파일 저장 후 path 만 마커 안에).
- **TUI 가 아닌 일반 shell** — pair 카운팅 동일하게 작동. shell echo 가 raw text 라 closed pair 1 + 응답 1 = 2 로 자연 일치.

## 확장 — fan-in / 진척 보고

다중 sidecar 동시 처리나 중간 진척 알림이 필요하면 `cmux events --category notification` + sidecar 의 `cmux notify` 결합. 단순 1:1 ask 엔 불필요.

## 안 쓰는 경우

- 패널만 열면 충분 → cmux 스킬
- 응답을 사용자가 직접 보면 되는 경우 → ack 불필요
- ack 불가능한 TUI (vim, k9s, btop) — 마커 echo 자체가 안 되므로 화면 안정 감지 fallback 필요
