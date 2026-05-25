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

## 2. 함수별 상세

### 2.1 `suf_send <surface> <prompt> [--mode llm|worker]`

송신만. fifo 생성 + cmux send. 즉시 리턴.

| 출력 | 내용 |
|---|---|
| stdout | `job_id` (한 줄) |
| stderr | `[suf v5] surface:9 (llm) sent, job=<id>` |
| RC | 0 정상 / 2 cap or arg / 3 detect 실패 / 4 mkfifo / 5 cmux send 실패 |

```bash
job=$(suf_send surface:9 "test 결과 한 줄 요약")
echo "job_id: $job"
# job_id: 1779694440788107000-30226-3269f5b8
```

### 2.2 `suf_collect <job> [--timeout N] [--response-max N]`

fifo blocking read. timeout/사이즈 호출 시점에 자유롭게.

| 출력 | 내용 |
|---|---|
| stdout | 응답 본문 |
| stderr | `[suf v5] collect <id> 12s 87B ok` |
| RC | 0 정상 / 6 no such job / 124 timeout |

```bash
result=$(suf_collect "$job" --timeout 1800)
# 30분까지 기다림
```

옵션:
- `--timeout 0` 은 즉시 timeout (= probe 와 동등하지만 sidecar 가 막 fifo write 시작한 경우 잘릴 위험. probe 는 `suf_check`)
- `--response-max 65536` 으로 4KB 기본 cap 우회

### 2.3 `suf_check <job>`

non-blocking probe. fifo 안에 data 가 흐르기 시작했나 확인.

| RC | 의미 |
|---|---|
| 0 | data ready — `suf_collect` 호출 적기 |
| 1 | 아직 안 도착 — 더 기다림 |
| 2 | no such job — 잘못된 id 또는 이미 collect 됨 |

```bash
job=$(suf_send surface:9 "오래 걸리는 작업")
while ! suf_check "$job"; do
  echo "기다리는 중..."
  sleep 5
done
result=$(suf_collect "$job")
```

### 2.4 `suf_tail <job> [--timeout N]`

line 단위 stream until EOF. sidecar 가 진척 line 흘릴 때 실시간 표시.

| 출력 | 내용 |
|---|---|
| stdout | 매 line raw |
| stderr | `[suf v5] tail done, 23 lines` |
| RC | 0 정상 EOF / 124 timeout / 5 open 실패 / 6 no such job |

**중요**: sidecar 가 **한 writer 로 line print + 마지막에 close** 해야 진척 stream 됨. `echo X >> $fifo` 반복은 매번 EOF — 한 줄만 받고 끝남.

올바른 sidecar 패턴 (LLM Bash tool):
```bash
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

parent:
```bash
job=$(suf_send surface:9 "위 build 진척 line 단위로")
suf_tail "$job" --timeout 600
# 각 line 실시간 출력
```

### 2.5 `suf_cancel <job> [--surface X]`

진행 중 job 취소. fifo unlink → parent 의 collect/tail 이 즉시 깨어남 (open fail rc=5). `--surface` 지정 시 sidecar 에 ESC 송신.

```bash
suf_cancel "$job" --surface surface:9
# fifo unlinked + surface:9 에 ESC
```

ESC 가 sidecar 작업을 멈출지는 sidecar 종류에 따름:
- Claude/Codex/Gemini TUI: 일반적으로 멈춤
- shell worker: ctrl-c 가 더 효과. `cmux send-key --surface X 'C-c'` 직접 호출 가능 (suf_cancel 은 ESC 만)

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
