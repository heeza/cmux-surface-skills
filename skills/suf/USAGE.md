# suf v5 — 사용 매뉴얼

`suf_ask` (동기) 와 fire-and-collect 비동기 API 5종의 실용 사용법.

기본 개념은 [`SKILL.md`](SKILL.md) 참조. 이 문서는 **어떤 패턴을 언제 쓰는지** 와 **실제 호출 예제** 에 집중.

---

## 1. 두 패턴 한눈에

```
[동기 — suf_ask]
parent ────send────▶ sidecar
parent ◀───receive── sidecar      (blocking 30s default)
   │
   결과 즉시 손에. 다른 일 못 함.

[비동기 — suf_send + suf_collect]
parent ────send────▶ sidecar       (suf_send 즉시 리턴)
   │
parent: 다른 일 ...
sidecar: 작업 ...
   │
parent ◀───receive── sidecar       (suf_collect 시점, timeout 자유)
   │
   결과 손에. 사이에 parent 다른 일 가능.
```

### 언제 어느 쪽?

| 케이스 | 추천 |
|---|---|
| 짧은 ack/조회 (< 30초 예상) | `suf_ask` |
| 5분 ~ 1시간 작업 | `suf_send` + `suf_collect --timeout N` |
| 진척 stream 필요 | `suf_send` + `suf_tail` |
| 동시 여러 sidecar 굴림 | N × `suf_send` → 모두 `suf_collect` |
| 작업 도중 취소 | `suf_send` + `suf_cancel` |
| 비차단 폴링 | `suf_send` + `suf_check` + `suf_collect` |

---

## 2. 함수별 상세 (8종)

각 함수는 **무엇 / 언제 / 시그니처 / 출력 / 예제 / 주의** 6 블록.

---

### 2.1 `suf_ask` — 동기 ask (가장 흔한 패턴)

- **무엇** — 한 호출로 송신 + 응답까지. parent blocking. v3/v4 의 핵심 API 와 같은 모양.
- **언제** — 짧은 ack/조회 (< 30초 예상). 99% 케이스. **default 첫 선택**.

**시그니처**:
```bash
suf_ask <surface> <prompt> [--mode llm|worker] [--timeout N]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | 응답 본문 |
| stderr | `[suf v5] surface:9 (llm) 4s 18B ok` |
| RC | 0 정상 / 2 cap 또는 인자 / 3 detect 실패 / 4 mkfifo / 5 send 실패 / 124 timeout |

**예제**:
```bash
ANSWER=$(suf_ask surface:9 "현재 브랜치만 한 줄로")
# main

ANSWER=$(suf_ask surface:6 "date +%H:%M" --mode worker)
# 16:34

ANSWER=$(suf_ask surface:9 "test 결과 한 줄" --timeout 120)
```

**주의** — prompt > 500자 면 즉시 reject. `suf_ask_unsafe` 또는 `SUF_V5_PROMPT_MAX` env 우회.

---

### 2.2 `suf_ask_unsafe` — cap 우회 동기 ask

- **무엇** — `suf_ask` 와 같지만 prompt/response cap 호출 시점에 자유. 호출자가 큰 작업 의도임을 명시.
- **언제** — PR 리뷰, 분석 리포트, 진짜로 큰 응답 필요. **드물게**.

**시그니처**:
```bash
suf_ask_unsafe <surface> <prompt> [--mode] [--timeout N] [--prompt-max N] [--response-max N]
```

**출력** — `suf_ask` 와 동일.

**예제**:
```bash
# 1KB prompt, 64KB 응답, 5분
result=$(suf_ask_unsafe surface:9 "$LONG_PROMPT" \
  --prompt-max 4000 --response-max 65536 --timeout 300)
```

**주의** — cap 풀어도 sidecar 가 큰 본문 생성 = 토큰 폭주. 함수 이름 자체에 `_unsafe` 박혀있는 이유 — git log / 코드 리뷰에서 의도적 호출 즉시 보임.

---

### 2.3 `suf_send` — 비동기 송신

- **무엇** — fifo 생성 + cmux send 까지만. parent 즉시 리턴. job_id stdout.
- **언제** — long task 위임 / parent 가 다른 일 병행 / multi-sidecar fan-in.

**시그니처**:
```bash
suf_send <surface> <prompt> [--mode llm|worker]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | job_id (한 줄, 변수에 capture) |
| stderr | `[suf v5] surface:9 (llm) sent, job=<id>` |
| RC | 0 정상 / 2 cap or arg / 3 detect 실패 / 4 mkfifo / 5 send 실패 |

**예제**:
```bash
job=$(suf_send surface:9 "test 결과 한 줄")
echo "job: $job"
# 1779694440788107000-30226-3269f5b8

# parent 다른 일 가능
do_other_work

# 나중에 결과 받기
result=$(suf_collect "$job")
```

**주의** — `suf_send` 만 호출하고 `suf_collect`/`suf_cancel` 안 부르면 fifo 누수. `/tmp/suf-fifo/` 청소 필요.

---

### 2.4 `suf_collect` — 비동기 수신

- **무엇** — fifo blocking read. 결과 stdout 출력 후 fifo unlink.
- **언제** — `suf_send` 의 결과 받기. 짧은 timeout loop 으로 안전 polling 도.

**시그니처**:
```bash
suf_collect <job> [--timeout N] [--response-max N]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | 응답 본문 |
| stderr | `[suf v5] collect <id> 12s 87B ok` |
| RC | 0 정상 / 6 no such job / 124 timeout |

**예제**:
```bash
# 단순 blocking 대기 (30분까지)
result=$(suf_collect "$job" --timeout 1800)

# 큰 응답 받기
log=$(suf_collect "$job" --response-max 65536 --timeout 600)

# 안전한 polling (race 없는 native pattern)
while ! result=$(suf_collect "$job" --timeout 5); do
  echo "안 옴, 다시 대기..."
done
```

**주의** — 같은 job 두 번 collect 못 함 (fifo unlink). RC=6 발생 시 잘못된 id 또는 이미 받은 거.

---

### 2.5 `suf_check` — non-blocking probe (with polling)

- **무엇** — fifo 의 writer 부착 / data 흐름 시작 여부 확인. polling 옵션 포함.
- **언제** — 가벼운 "작업 시작했나" 신호. **진짜 데이터 안전 수신은 `suf_collect` 권장**.

**시그니처**:
```bash
suf_check <job> [--wait N] [--poll-interval F]
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
suf_check "$job"; echo $?   # 1 또는 0

# 5분까지 자동 폴링
suf_check "$job" --wait 300 && result=$(suf_collect "$job")
```

**주의** — ⚠️ **destructive race**: check 가 nonblocking open + close 사이에 sidecar 의 writer 가 write 시작 중이면 SIGPIPE → collect 가 빈 응답 받는 케이스 발생. **진짜 안전한 폴링은 `suf_collect --timeout 5` 자체** (kernel blocking read 이 native polling, race 없음).

---

### 2.6 `suf_tail` — 진척 line stream

- **무엇** — fifo 의 writer 가 line 단위로 보내는 출력을 실시간 stdout 으로 stream.
- **언제** — build/deploy/test 진척 로그를 sidecar 에서 실시간 받기.

**시그니처**:
```bash
suf_tail <job> [--timeout N]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | 매 line raw (autoflush) |
| stderr | (끝났을 때) `[suf v5] tail done, 23 lines` |
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
} > /tmp/suf-fifo/<job>.res
```

parent 쪽:
```bash
job=$(suf_send surface:9 "위 4단계 progress 흘려라")
suf_tail "$job" --timeout 600 | tee build.log
# 라인마다 즉시 화면 + log 파일
```

**주의** — sidecar 가 `echo line >> $fifo` 반복하면 매번 EOF — tail 첫 줄만 받고 종료. **반드시 한 writer 로 묶어야** stream 작동.

---

### 2.7 `suf_cancel` — 진행 중 job 취소

- **무엇** — fifo unlink (parent 측 정리) + optional sidecar 에 ESC 키 송신.
- **언제** — long task 도중 사용자 의지로 끊기 / timeout fallback / 잘못 보낸 job 회수.

**시그니처**:
```bash
suf_cancel <job> [--surface X]
```

**출력**:

| 채널 | 내용 |
|---|---|
| stderr | `[suf v5] cancel <id> (fifo unlinked + ESC sent)` |
| RC | 0 |

**예제**:
```bash
# parent 측만 정리 (sidecar 작업은 계속)
suf_cancel "$job"

# sidecar 작업도 끊기 시도 (ESC)
suf_cancel "$job" --surface surface:9

# timeout 후 fallback 패턴
if ! result=$(suf_collect "$job" --timeout 60); then
  suf_cancel "$job" --surface surface:9
  # 다른 sidecar 로 재시도
fi
```

**주의** — ESC 가 sidecar 작업을 진짜 끊을지는 종류 따라 다름:
- Claude/Codex/Gemini TUI: 일반적으로 멈춤
- shell worker: ctrl-c 가 더 효과. `cmux send-key --surface X 'C-c'` 직접 가능 (suf_cancel 은 ESC 만)

---

### 2.8 `suf_other_surfaces` — discovery

- **무엇** — 같은 workspace 의 self 가 아닌 다른 surface 목록 (cross-workspace 자동 제외).
- **언제** — 자동 sidecar 선택 / 사용 가능한 surface 확인 / 충돌 회피.

**시그니처**:
```bash
suf_other_surfaces
```

**출력**:

| 채널 | 내용 |
|---|---|
| stdout | surface ref 한 줄씩 (`surface:9` 등) |
| RC | 0 정상 / 1 cmux tree 실패 또는 workspace 못 찾음 |

**예제**:
```bash
suf_other_surfaces
# surface:9
# surface:11
# surface:13

# 첫 번째 surface 자동 선택
target=$(suf_other_surfaces | head -1)
suf_ask "$target" "ping"

# 모두에 동시 ping (fan-out)
for s in $(suf_other_surfaces); do
  suf_send "$s" "현황 한 줄"
done
```

**주의** — cross-workspace 의도된 미지원. 다른 ws 의 surface 가 필요하면 그 ws 의 cmux send 직접 호출 (lib 우회).

---

## 3. 실용 시나리오

### 3.1 build watch — 5분 작업, 결과만 받기

```bash
source ~/.agents/skills/suf/scripts/suf-v5-lib.sh

job=$(suf_send surface:9 "npm run build && echo done > /tmp/suf-fifo/$job.res")
# (실제로는 auto-cap 문구가 자동 첨부됨)
result=$(suf_collect "$job" --timeout 600)
echo "build: $result"
```

### 3.2 multi-sidecar 병렬 fan-in

```bash
# 3개 sidecar 동시 굴림
j1=$(suf_send surface:9  "claude 로 PR 9 리뷰")
j2=$(suf_send surface:11 "agy 로 PR 9 리뷰")
j3=$(suf_send surface:13 "codex 로 PR 9 리뷰")

# 다 받음
r1=$(suf_collect "$j1" --timeout 600)
r2=$(suf_collect "$j2" --timeout 600)
r3=$(suf_collect "$j3" --timeout 600)

# self 가 종합
echo "=== claude ==="; echo "$r1"
echo "=== agy ===";    echo "$r2"
echo "=== codex ===";  echo "$r3"
```

### 3.3 비차단 폴링 — UI 응답성 유지

```bash
job=$(suf_send surface:9 "오래 걸리는 분석")

for i in 1 2 3 4 5; do
  if suf_check "$job"; then
    result=$(suf_collect "$job")
    echo "got: $result"; break
  fi
  echo "여전히 작업 중 ($i/5)"
  # 다른 일 진행
  sleep 10
done
```

### 3.4 진척 stream — 실시간 빌드 로그

```bash
job=$(suf_send surface:9 "build 진척을 line 단위로 흘려라")

# 별도 background tail 시작
suf_tail "$job" --timeout 1800 | tee build.log &
TAIL_PID=$!

# parent 는 다른 일
do_other_work

# 작업 끝 기다림
wait $TAIL_PID
```

### 3.5 dialog — 다단계 위임

```bash
# round 1
j1=$(suf_send surface:9 "DB 분석. 가장 큰 테이블 한 줄로")
big=$(suf_collect "$j1" --timeout 600)
echo "biggest: $big"

# round 2 (전 라운드 답 활용)
j2=$(suf_send surface:9 "$big 테이블에 index 추가 SQL 한 줄로")
sql=$(suf_collect "$j2" --timeout 60)
echo "sql: $sql"
```

### 3.6 timeout 회복 — cancel 후 재시도

```bash
job=$(suf_send surface:9 "task X")
if ! result=$(suf_collect "$job" --timeout 60); then
  echo "timeout. canceling..."
  suf_cancel "$job" --surface surface:9
  
  # 다른 sidecar 로 fallback
  job2=$(suf_send surface:11 "task X (fallback)")
  result=$(suf_collect "$job2" --timeout 120)
fi
```

---

## 4. 함정 / 주의

### 4.1 prompt 의 cap 은 send 에도 적용

`suf_send` 도 500자 cap. 우회는 `suf_ask_unsafe` 만 (동기). 비동기 unsafe 가 필요하면 직접 `SUF_V5_PROMPT_MAX=99999 suf_send ...` 형태로 한 줄 export.

### 4.2 job leak

`suf_send` 후 `suf_collect` 안 부르면 fifo 영원히 남음. crash 등 비정상 종료 시 누적. 청소:

```bash
ls -la /tmp/suf-fifo/
rm -f /tmp/suf-fifo/*.res    # 안전 — fifo 만 있음
```

### 4.3 같은 job 두 번 collect 금지

`suf_collect` 가 fifo unlink. 같은 id 로 다시 호출하면 RC=6 (no such job). 한 job 한 번.

### 4.4 sidecar 가 fifo write 안 함

prompt 의 auto-cap 안내문 (`printf "..." > /tmp/suf-fifo/<job>.res`) 을 sidecar 가 무시하면 timeout. 보통 LLM 의 Bash tool permission 문제. `--dangerously-skip-permissions` 류 모드 필요.

### 4.5 worker mode + 큰 stdout

`{ command; } > $fifo 2>&1` 패턴이라 command 가 100KB stdout 흘리면 fifo buffer 가득 차서 sidecar 가 block. parent 가 read 시작해야 풀림. parent 가 send 직후 즉시 collect (또는 tail) 호출 권장.

### 4.6 suf_tail 은 한 writer 가정

`echo line >> fifo` 반복은 한 줄당 EOF — `tail` 이 첫 줄만 받고 종료. 한 writer 로 묶어야 stream. SKILL.md 의 sidecar 협조 패턴 참조.

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

---

## 6. 환경변수

[SKILL.md 환경변수](SKILL.md#환경변수) 참조. 핵심:

- `SUF_V5_QUIET=on` — stderr status line 끔
- `SUF_V5_TIMEOUT=300` — 동기/비동기 default timeout
- `SUF_V5_RESPONSE_MAX=65536` — 응답 cap 늘림
- `SUF_V5_ENTER_DELAY=0.3` — Enter race 더 보수적

---

## 7. 최소 예제 모음

복사 붙여넣기 가능한 5줄 이내 예제.

```bash
# 동기 한 줄
ans=$(suf_ask surface:9 "현재 시간")

# 비동기 — 보내고 1분 뒤 받기
j=$(suf_send surface:9 "task X"); sleep 60; ans=$(suf_collect "$j")

# 폴링
j=$(suf_send surface:9 "task"); while ! suf_check "$j"; do sleep 5; done; ans=$(suf_collect "$j")

# 진척 stream
j=$(suf_send surface:9 "build 진척"); suf_tail "$j" --timeout 1800

# 취소
j=$(suf_send surface:9 "long task"); sleep 10; suf_cancel "$j" --surface surface:9
```
