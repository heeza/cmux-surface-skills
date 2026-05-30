# cmux v5 — 사용 매뉴얼

`cmux_ask` (동기) 와 fire-and-collect 비동기 API 5종의 실용 사용법.

기본 개념은 [`SKILL.md`](SKILL.md) 참조. 이 문서는 **어떤 패턴을 언제 쓰는지** 와 **실제 호출 예제** 에 집중.

---

## 1. 두 패턴 한눈에

```
[동기 — cmux_ask]
parent ────send────▶ sidecar
parent ◀───receive── sidecar      (blocking 30s default)
   │
   결과 즉시 손에. 다른 일 못 함.

[비동기 — cmux_send + cmux_collect]
parent ────send────▶ sidecar       (cmux_send 즉시 리턴)
   │
parent: 다른 일 ...
sidecar: 작업 ...
   │
parent ◀───receive── sidecar       (cmux_collect 시점, timeout 자유)
   │
   결과 손에. 사이에 parent 다른 일 가능.
```

### 언제 어느 쪽?

| 케이스 | 추천 |
|---|---|
| 짧은 ack/조회 (< 30초 예상) | `cmux_ask` |
| 5분 ~ 1시간 작업 | `cmux_send` + `cmux_collect --timeout N` |
| 진척 stream 필요 | `cmux_send` + `cmux_tail` |
| 동시 여러 sidecar 굴림 | N × `cmux_send` → 모두 `cmux_collect` |
| 작업 도중 취소 | `cmux_send` + `cmux_cancel` |
| 비차단 폴링 | `cmux_send` + `cmux_check` + `cmux_collect` |

---

## 1.5. 함수 선택 가이드 (한눈에)

상황별 권장 함수.

| 상황 | 함수 | 이유 |
|---|---|---|
| 30초 안 답 받을 짧은 ack/조회 | **`cmux_ask`** | 가장 단순. blocking 한 번 |
| 큰 prompt / 큰 응답 의도적으로 | `cmux_ask_unsafe` | cap 우회. 의도 명시 |
| 5분 ~ 1시간 long task | **`cmux_send` + `cmux_collect`** | parent blocking 분리 |
| 여러 sidecar 동시 굴림 (fan-in) | `cmux_send` ×N → `cmux_collect` ×N | 병렬 |
| 진척 로그 실시간으로 봐야 함 | **`cmux_tail`** | line 단위 즉시 표시 |
| 사이드카 작업 시작했나 가벼운 확인 | `cmux_check` (조심) | ⚠️ race — collect short timeout 권장 |
| 안전한 polling (race 없이 대기) | `cmux_collect --timeout 5` 반복 | kernel blocking = native polling |
| 진행 중 작업 중단 | `cmux_cancel` | fifo unlink + 옵션 ESC |
| 어느 surface 에 보낼지 자동 선택 | `cmux_other_surfaces` | discovery |

### "ask vs send/collect" 빠른 결정

```
30초 안에 끝남? ──── yes ──▶ cmux_ask
       │
       no
       │
       ▼
parent 가 사이에 다른 일 함? ── no ──▶ cmux_ask --timeout N 길게
       │
       yes
       │
       ▼
cmux_send + cmux_collect
```

### "collect vs tail" 빠른 결정

```
진척을 실시간으로 봐야 함? ── yes ──▶ cmux_tail
                                      (sidecar 가 한 writer 로 line print 필요)
       │
       no (결과만 한 번)
       │
       ▼
cmux_collect
```

---

## 2. 함수별 상세 (8종)

각 함수는 **무엇 / 언제 / 시그니처 / 출력 / 예제 / 주의** 6 블록.

---

### 2.1 `cmux_ask` — 동기 ask (가장 흔한 패턴)

- **무엇** — 한 호출로 송신 + 응답까지. parent blocking. v3/v4 의 핵심 API 와 같은 모양.
- **언제** — 짧은 ack/조회 (< 30초 예상). 99% 케이스. **default 첫 선택**.

**시그니처**:
```bash
cmux_ask <surface> <prompt> [--mode llm|worker] [--timeout N]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | 응답 본문 |
| stderr | `[cmux v5] surface:9 (llm) 4s 18B ok` |
| RC | 0 정상 / 2 cap 또는 인자 / 3 detect 실패 / 4 mkfifo / 5 send 실패 / 124 timeout |

**예제**:
```bash
ANSWER=$(cmux_ask surface:9 "현재 브랜치만 한 줄로")
# main

ANSWER=$(cmux_ask surface:6 "date +%H:%M" --mode worker)
# 16:34

ANSWER=$(cmux_ask surface:9 "test 결과 한 줄" --timeout 120)
```

**주의** — prompt > 500자 면 즉시 reject. `cmux_ask_unsafe` 또는 `CMUX_V5_PROMPT_MAX` env 우회.

---

### 2.2 `cmux_ask_unsafe` — cap 우회 동기 ask

- **무엇** — `cmux_ask` 와 같지만 prompt/response cap 호출 시점에 자유. 호출자가 큰 작업 의도임을 명시.
- **언제** — PR 리뷰, 분석 리포트, 진짜로 큰 응답 필요. **드물게**.

**시그니처**:
```bash
cmux_ask_unsafe <surface> <prompt> [--mode] [--timeout N] [--prompt-max N] [--response-max N]
```

**출력** — `cmux_ask` 와 동일.

**예제**:
```bash
# 1KB prompt, 64KB 응답, 5분
result=$(cmux_ask_unsafe surface:9 "$LONG_PROMPT" \
  --prompt-max 4000 --response-max 65536 --timeout 300)
```

**주의** — cap 풀어도 sidecar 가 큰 본문 생성 = 토큰 폭주. 함수 이름 자체에 `_unsafe` 박혀있는 이유 — git log / 코드 리뷰에서 의도적 호출 즉시 보임.

---

### 2.3 `cmux_send` — 비동기 송신

- **무엇** — fifo 생성 + cmux send 까지만. parent 즉시 리턴. job_id stdout.
- **언제** — 다음 4가지 케이스. 그 외엔 `cmux_ask` 가 더 간단.

| 케이스 | 설명 |
|---|---|
| ① long task 위임 | 5분~1시간 작업. `cmux_ask` 의 30초 default 로는 timeout. |
| ② parent 가 사이에 다른 일 | send 즉시 리턴 → parent 가 코드 짜고/파일 읽고/다른 sidecar 호출 가능. |
| ③ multi-sidecar 병렬 | 3 sidecar 동시 굴림 — N×`cmux_send` → N×`cmux_collect`. 직렬 대비 N배 빠름. |
| ④ 진척 stream | `cmux_send` → `cmux_tail` 콤보. tail 은 fifo 가 이미 있어야 작동. |

**시그니처**:
```bash
cmux_send <surface> <prompt> [--mode llm|worker]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | job_id (한 줄, 변수에 capture) |
| stderr | `[cmux v5] surface:9 (llm) sent, job=<id>` |
| RC | 0 정상 / 2 cap or arg / 3 detect 실패 / 4 mkfifo / 5 send 실패 |

**예제**:
```bash
job=$(cmux_send surface:9 "test 결과 한 줄")
echo "job: $job"
# 1779694440788107000-30226-3269f5b8

# parent 다른 일 가능
do_other_work

# 나중에 결과 받기
result=$(cmux_collect "$job")
```

**주의** — `cmux_send` 만 호출하고 `cmux_collect`/`cmux_cancel` 안 부르면 fifo 누수. `/tmp/cmux-fifo/` 청소 필요.

---

### 2.4 `cmux_collect` — 비동기 수신

- **무엇** — fifo blocking read. 결과 stdout 출력 후 fifo unlink.
- **언제** — `cmux_send` 와 짝. 다음 4 시나리오.

| 케이스 | 설명 |
|---|---|
| ① long task 결과 받기 | send 후 30분까지 기다림. `--timeout 1800`. |
| ② fan-in 종합 | N 송신 → N collect. 마지막에 self 가 결과 종합. |
| ③ 안전한 polling (race 없음) | `while ! result=$(cmux_collect "$job" --timeout 5); do :; done` — kernel blocking read 가 native, `cmux_check` 의 race 없음. |
| ④ timeout 후 fallback | rc=124 시 다른 sidecar 로 재시도. |

**`cmux_ask` 와의 차이**: `cmux_ask` = send + collect 한 번. collect 단독 = 이미 send 된 job 의 결과만. parent 가 send 와 collect 사이에 자유롭게 다른 일 가능.

**시그니처**:
```bash
cmux_collect <job> [--timeout N] [--response-max N]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | 응답 본문 |
| stderr | `[cmux v5] collect <id> 12s 87B ok` |
| RC | 0 정상 / 6 no such job / 124 timeout |

**예제**:
```bash
# 단순 blocking 대기 (30분까지)
result=$(cmux_collect "$job" --timeout 1800)

# 큰 응답 받기
log=$(cmux_collect "$job" --response-max 65536 --timeout 600)

# 안전한 polling (race 없는 native pattern)
while ! result=$(cmux_collect "$job" --timeout 5); do
  echo "안 옴, 다시 대기..."
done
```

**주의** — 같은 job 두 번 collect 못 함 (fifo unlink). RC=6 발생 시 잘못된 id 또는 이미 받은 거.

---

### 2.5 `cmux_check` — non-blocking probe (with polling)

- **무엇** — fifo 의 writer 부착 / data 흐름 시작 여부 확인. polling 옵션 포함.
- **언제** — 가벼운 "작업 시작했나" 신호. **진짜 데이터 안전 수신은 `cmux_collect` 권장**.

**시그니처**:
```bash
cmux_check <job> [--wait N] [--poll-interval F]
```

**출력**:

| RC | 의미 |
|---|---|
| 0 | writer attached or data 있음 |
| 1 | 아직 (또는 `--wait N` deadline 초과) |
| 2 | no such job (잘못된 id 또는 이미 collect 됨) |

옵션:
- `--wait N` — N초까지 내부 폴링. ready 즉시 rc=0.
- `--poll-interval F` — 폴링 주기 (기본 0.2s).

**예제**:
```bash
# 즉시 probe
cmux_check "$job"; echo $?   # 1 또는 0

# 5분까지 자동 폴링
cmux_check "$job" --wait 300 && result=$(cmux_collect "$job")
```

**주의** — **v5.2 안정성 향상**: 과거 버전에서 발생하던 destructive race(sysopen/close 반복 시 SIGPIPE 유발) 현상은 v5.2부터 `lsof` 기반의 Non-destructive Check 기술로 완벽히 예방되었습니다. 이제 안심하고 `cmux_check`를 사용할 수 있습니다.

---

### 2.6 `cmux_tail` — 진척 line stream

- **무엇** — fifo 의 writer 가 line 단위로 보내는 출력을 실시간 stdout 으로 stream (autoflush 적용).
- **언제** — 다음 3 케이스. **결과만 필요하면 `cmux_collect` 가 더 단순**.

| 케이스 | 설명 |
|---|---|
| ① 진척 단계별 확인 | build/deploy/test 의 단계별 메시지 ("[1/4] cloning...", "[2/4] installing..."). collect 면 끝까지 0byte 보이다 한꺼번에 dump. |
| ② 흐름 보고 도중 cancel | 이상한 line 보이면 사용자가 `cmux_cancel` 결정. |
| ③ `tee` 로 log 동시 저장 | `cmux_tail "$job" \| tee build.log` — 화면 + 파일 동시. |

**`cmux_collect` 와의 차이**: collect 는 EOF 후 한꺼번에 stdout. tail 은 line 도착 즉시 stdout. **`cmux_tail` 은 sidecar 가 한 writer 로 line print + close 패턴 따라야 작동** — `echo >> $fifo` 반복 시 매 line 마다 EOF 라 첫 줄만 받고 종료. 안 따르면 collect 가 더 안전.

**시그니처**:
```bash
cmux_tail <job> [--timeout N]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | 매 line raw (autoflush) |
| stderr | (끝났을 때) `[cmux v5] tail done, 23 lines` |
| RC | 0 정상 EOF / 124 timeout / 5 open 실패 / 6 no such job |

**예제** (sidecar 가 진척 흘려야 작동):

sidecar 쪽 패턴:
```bash
# Bash tool 한 호출로 묶음. >> append 아니라 > truncate + 한 writer.
{
  echo "[1/4] cloning..."
  git clone ...
  echo "[2/4] installing..."
  npm install
  echo "[3/4] testing..."
  npm test
  echo "[4/4] done"
} > /tmp/cmux-fifo/<job>.res
```

parent 쪽:
```bash
job=$(cmux_send surface:9 "위 4단계 progress 흘려라")
cmux_tail "$job" --timeout 600 | tee build.log
# 라인마다 즉시 화면 + log 파일
```

**주의** — **v5.2 Persistent 스트리밍**: 과거 버전에서는 `>>`를 통해 여러 차례 쪼개서 쓸 때 조기 종료되는 한계가 있었으나, v5.2부터는 Persistent Tail 방식이 도입되어 sidecar 프로세스가 실행 중인 동안에는 EOF를 만나더라도 FIFO를 자동 재오픈하여 계속 추적합니다.

---

### 2.7 `cmux_cancel` — 진행 중 job 취소

- **무엇** — fifo unlink (parent 측 정리) + optional sidecar 에 ESC 키 송신.
- **언제** — long task 도중 사용자 의지로 끊기 / timeout fallback / 잘못 보낸 job 회수.

**시그니처**:
```bash
cmux_cancel <job> [--surface X]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stderr | `[cmux v5] cancel <id> (fifo unlinked + ESC sent)` |
| RC | 0 |

**예제**:
```bash
# parent 측만 정리 (sidecar 작업은 계속)
cmux_cancel "$job"

# sidecar 작업도 끊기 시도 (ESC)
cmux_cancel "$job" --surface surface:9

# timeout 후 fallback 패턴
if ! result=$(cmux_collect "$job" --timeout 60); then
  cmux_cancel "$job" --surface surface:9
  # 다른 sidecar 로 재시도
fi
```

**주의** — ESC 가 sidecar 작업을 진짜 끊을지는 종류 따라 다름:
- Claude/Codex/Gemini TUI: 일반적으로 멈춤
- shell worker: ctrl-c 가 더 효과. `cmux send-key --surface X 'C-c'` 직접 가능 (cmux_cancel 은 ESC 만)

---

### 2.8 `cmux_other_surfaces` — discovery

- **무엇** — 같은 workspace 의 self 가 아닌 다른 surface 목록 (cross-workspace 자동 제외).
- **언제** — 자동 sidecar 선택 / 사용 가능한 surface 확인 / 충돌 회피.

**시그니처**:
```bash
cmux_other_surfaces
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | surface ref 한 줄씩 (`surface:9` 등) |
| RC | 0 정상 / 1 cmux tree 실패 또는 workspace 못 찾음 |

**예제**:
```bash
cmux_other_surfaces
# surface:9
# surface:11
# surface:13

# 첫 번째 surface 자동 선택
target=$(cmux_other_surfaces | head -1)
cmux_ask "$target" "ping"

# 모두에 동시 ping (fan-out)
for s in $(cmux_other_surfaces); do
  cmux_send "$s" "현황 한 줄"
done
```

**주의** — cross-workspace 의도된 미지원. 다른 ws 의 surface 가 필요하면 그 ws 의 cmux send 직접 호출 (lib 우회).

---

## 3. 실용 시나리오

### 3.1 build watch — 5분 작업, 결과만 받기

```bash
source ~/.agents/skills/cmux/scripts/cmux-v5-lib.sh

job=$(cmux_send surface:9 "npm run build && echo done > /tmp/cmux-fifo/$job.res")
# (실제로는 auto-cap 문구가 자동 첨부됨)
result=$(cmux_collect "$job" --timeout 600)
echo "build: $result"
```

### 3.2 multi-sidecar 병렬 fan-in

```bash
# 3개 sidecar 동시 굴림
j1=$(cmux_send surface:9  "claude 로 PR 9 리뷰")
j2=$(cmux_send surface:11 "agy 로 PR 9 리뷰")
j3=$(cmux_send surface:13 "codex 로 PR 9 리뷰")

# 다 받음
r1=$(cmux_collect "$j1" --timeout 600)
r2=$(cmux_collect "$j2" --timeout 600)
r3=$(cmux_collect "$j3" --timeout 600)

# self 가 종합
echo "=== claude ==="; echo "$r1"
echo "=== agy ===";    echo "$r2"
echo "=== codex ===";  echo "$r3"
```

### 3.3 비차단 폴링 — UI 응답성 유지

```bash
job=$(cmux_send surface:9 "오래 걸리는 분석")

for i in 1 2 3 4 5; do
  if cmux_check "$job"; then
    result=$(cmux_collect "$job")
    echo "got: $result"; break
  fi
  echo "여전히 작업 중 ($i/5)"
  # 다른 일 진행
  sleep 10
done
```

### 3.4 진척 stream — 실시간 빌드 로그

```bash
job=$(cmux_send surface:9 "build 진척을 line 단위로 흘려라")

# 별도 background tail 시작
cmux_tail "$job" --timeout 1800 | tee build.log &
TAIL_PID=$!

# parent 는 다른 일
do_other_work

# 작업 끝 기다림
wait $TAIL_PID
```

### 3.5 dialog — 다단계 위임

```bash
# round 1
j1=$(cmux_send surface:9 "DB 분석. 가장 큰 테이블 한 줄로")
big=$(cmux_collect "$j1" --timeout 600)
echo "biggest: $big"

# round 2 (전 라운드 답 활용)
j2=$(cmux_send surface:9 "$big 테이블에 index 추가 SQL 한 줄로")
sql=$(cmux_collect "$j2" --timeout 60)
echo "sql: $sql"
```

### 3.6 timeout 회복 — cancel 후 재시도

```bash
job=$(cmux_send surface:9 "task X")
if ! result=$(cmux_collect "$job" --timeout 60); then
  echo "timeout. canceling..."
  cmux_cancel "$job" --surface surface:9
  
  # 다른 sidecar 로 fallback
  job2=$(cmux_send surface:11 "task X (fallback)")
  result=$(cmux_collect "$job2" --timeout 120)
fi
```

---

## 4. 함정 / 주의

### 4.1 prompt 의 cap 은 send 에도 적용

`cmux_send` 도 500자 cap. 우회는 `cmux_ask_unsafe` 만 (동기). 비동기 unsafe 가 필요하면 직접 `CMUX_V5_PROMPT_MAX=99999 cmux_send ...` 형태로 한 줄 export.

### 4.2 job leak

`cmux_send` 후 `cmux_collect` 안 부르면 fifo 영원히 남음. crash 등 비정상 종료 시 누적. 청소:

```bash
ls -la /tmp/cmux-fifo/
rm -f /tmp/cmux-fifo/*.res    # 안전 — fifo 만 있음
```

### 4.3 같은 job 두 번 collect 금지

`cmux_collect` 가 fifo unlink. 같은 id 로 다시 호출하면 RC=6 (no such job). 한 job 한 번.

### 4.4 sidecar 가 fifo write 안 함

prompt 의 auto-cap 안내문 (`printf "..." > /tmp/cmux-fifo/<job>.res`) 을 sidecar 가 무시하면 timeout. 보통 LLM 의 Bash tool permission 문제. `--dangerously-skip-permissions` 류 모드 필요.

### 4.5 worker mode + 큰 stdout

`{ command; } > $fifo 2>&1` 패턴이라 command 가 100KB stdout 흘리면 fifo buffer 가득 차서 sidecar 가 block. parent 가 read 시작해야 풀림. parent 가 send 직후 즉시 collect (또는 tail) 호출 권장.

### 4.6 cmux_tail 의 Multi-Writer 지원 (v5.2)

과거 버전에서는 `echo line >> fifo` 반복 시 매번 EOF가 감지되어 첫 줄만 받고 tail이 종료되는 이슈가 있었습니다. v5.2부터는 TTY 감시 기반의 Persistent Tail 모드가 도입되어, sidecar 프로세스가 완전히 종료되기 전까지는 FIFO를 반복 재오픈하며 정상 스트리밍합니다.

---

## 5. RC 코드 빠른 참조

| RC | 의미 |
|---|---|
| 0 | 정상 |
| 2 | prompt cap 초과 / 잘못된 인자 / 잘못된 mode |
| 3 | sidecar auto-detect 실패 (`--mode` 필요) |
| 4 | mkfifo 실패 |
| 5 | cmux send / fifo open 실패 |
| 6 | no such job (collect/check/tail) |
| 124 | timeout |
| 125 | early_idle (sidecar가 FIFO에 쓰지 않고 대기 상태/shell 프롬프트로 복귀) |

---

## 6. 환경변수

[SKILL.md 기본값](SKILL.md#기본값) 참조. 핵심:

- `CMUX_V5_QUIET=on` — stderr status line 끔
- `CMUX_V5_TIMEOUT=1200` — 동기/비동기 default timeout (20분)
- `CMUX_V5_RESPONSE_MAX=65536` — 응답 cap 늘림
- `CMUX_V5_PROMPT_STYLE=compact` — LLM 주입 규칙을 짧게 유지 (default)
- `CMUX_V5_FALLBACK_SCREEN=on` — Bash/FIFO 실패 시에만 screen marker fallback opt-in
- `CMUX_V5_EARLY_IDLE=worker` — timeout 전 실패 감지가 필요할 때만 polling 활성화
- `CMUX_V5_ENTER_DELAY=0.3` — Enter race 더 보수적
- `CMUX_V5_POLL_INTERVAL=1` — early-idle polling 주기 (초)
- `CMUX_V5_MAX_IDLE_CHECKS=10` — early-idle 무반응 판단 임계 횟수

---

## 7. 최소 예제 모음

복사 붙여넣기 가능한 5줄 이내 예제.

```bash
# 동기 한 줄
ans=$(cmux_ask surface:9 "현재 시간")

# 비동기 — 보내고 1분 뒤 받기
j=$(cmux_send surface:9 "task X"); sleep 60; ans=$(cmux_collect "$j")

# 폴링
j=$(cmux_send surface:9 "task"); while ! cmux_check "$j"; do sleep 5; done; ans=$(cmux_collect "$j")

# 진척 stream
j=$(cmux_send surface:9 "build 진척"); cmux_tail "$j" --timeout 1800

# 취소
j=$(cmux_send surface:9 "long task"); sleep 10; cmux_cancel "$j" --surface surface:9
```
