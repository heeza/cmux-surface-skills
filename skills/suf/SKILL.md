---
name: suf
description: cmux sidecar 사이의 agent-to-agent 통신. v5 부터 FIFO 응답 채널 + cap-discipline + sidecar 자동 감지 (LLM | shell worker). 짧은 ack/조회/단일 명령 위임에만 사용. 큰 작업 위임 금지 — 토큰 폭주.
---

# suf v5 — disciplined sidecar talk

## 핵심 변경 (v3/v4 → v5)

| 항목 | v3/v4 | v5 |
|---|---|---|
| 응답 채널 | `read-screen` 폴링 + 마커 추출 | **per-job FIFO blocking read** |
| 채널 noise | ANSI / single-line marker / scrollback 한계 | 0 — kernel pipe 직통 |
| sidecar 정체 | 사용자가 알아서 | **자동 감지** (LLM vs worker) |
| token discipline | 없음 | **4종 cap** (prompt/response/timeout/auto-cap 문구) |
| escape valve | — | `suf_ask_unsafe` 명시적 opt-in |

## 언제 쓰나 (그리고 안 쓰나)

✅ **쓰는 경우**
- 다른 surface 의 짧은 ack / pong / 상태 한 줄
- 단일 shell command 위임 (worker mode) — git/ls/date 같은 한 줄
- yes/no 결정 위임

❌ **절대 쓰지 마라**
- "리포트 작성", "분석", "수천 단어 분량" — sidecar 가 본인 토큰으로 폭주
- "가상 메시지 N개 생성 (N≥10)"
- "긴 코드 / 문서 / 설계" — file 모드도 토큰 절약 아님
- 큰 작업이면 **parent (self) 가 직접 처리**가 항상 더 쌈

## 한 사이클

```
parent: suf_ask <surface-or-title> <prompt>
  ├─ 1) prompt cap 검사 (≤500자 default)
  ├─ 2) 모드 자동 감지: ps → "llm" | "worker" | "unknown"
  ├─ 3) JOB id 생성, /tmp/suf-fifo/<JOB>.res mkfifo
  ├─ 4) prompt + 모드별 auto-cap 문구 첨부
  ├─ 5) cmux send (PTY 입력창) + Enter
  └─ 6) perl alarm + sysread 로 FIFO blocking read
        (timeout 30s default, max 4KB)
                  ▲
sidecar:          │
  llm:    답 작성 → Bash: printf "..." > /tmp/suf-fifo/<JOB>.res
  worker: { command ; } > /tmp/suf-fifo/<JOB>.res 2>&1
```

## 사용

### 동기 (한 줄 ack)

```bash
source ~/.agents/skills/suf/scripts/suf-v5-lib.sh
ANSWER=$(suf_ask "Claude Main" "현재 브랜치만 한 줄로")   # title 로 자동 매핑
ANSWER=$(suf_ask surface:9 "현재 브랜치만 한 줄로")       # 기존 surface ref 도 유지
ANSWER=$(suf_ask "Worker Shell" "git log -5 --oneline" --mode worker)
ANSWER=$(suf_ask_unsafe "Claude Main" "$LONG" --prompt-max 4000 --response-max 65536 --timeout 180)
```

### 비동기 (long task, fire-and-collect)

```bash
# 1) 송신만 — parent 즉시 자유. job_id stdout.
job=$(suf_send "Claude Main" "build 끝나면 한 줄 요약")

# 2-a) 나중에 blocking collect (timeout 길게)
result=$(suf_collect "$job" --timeout 1800)

# 2-b) non-blocking 체크 (polling 패턴)
if suf_check "$job"; then result=$(suf_collect "$job"); fi

# 2-c) 진척 stream (sidecar 가 한 writer 로 line 단위 print + close 패턴)
suf_tail "$job" --timeout 600

# 3) 도중 취소
suf_cancel "$job" --surface surface:9   # fifo unlink + ESC 송신
```

### Discovery

```bash
suf_other_surfaces   # 같은 workspace 의 다른 surface (cross-ws 자동 제외)
```

## API

| 함수 | 시그니처 | 비고 |
|---|---|---|
| `suf_ask` | `<surface-or-title> <prompt> [--mode llm\|worker] [--timeout N]` | 동기. cap 강제. title 자동 매핑 |
| `suf_ask_unsafe` | `<surface-or-title> <prompt> [--mode] [--timeout N] [--prompt-max N] [--response-max N]` | 동기. escape valve |
| `suf_send` | `<surface-or-title> <prompt> [--mode]` | **비동기 송신**. stdout=job_id. title 자동 매핑 |
| `suf_collect` | `<job> [--timeout N] [--response-max N]` | **비동기 수신**. blocking read |
| `suf_check` | `<job> [--wait N] [--poll-interval F]` | non-blocking probe. rc 0=ready, 1=not yet, 2=no job. ⚠️ destructive race 가능 — 함정 섹션 참조 |
| `suf_tail` | `<job> [--timeout N]` | line 단위 stream until EOF |
| `suf_cancel` | `<job> [--surface X]` | fifo unlink + (optional) ESC 송신 |
| `suf_other_surfaces` | 인자 없음 | 같은 ws 의 다른 surface |
| `suf_by_title` | `<title> <prompt> [opts]` | 호환용 wrapper. `suf_ask <title> ...` 권장 |

### exit codes

| RC | 의미 |
|---|---|
| 0 | 성공 (응답 stdout) |
| 2 | prompt cap 초과 / 잘못된 인자 / 잘못된 mode |
| 3 | sidecar 모드 auto-detect 실패 (`--mode` 명시 필요) |
| 4 | mkfifo 실패 |
| 5 | title match 없음 / cmux send 실패 (surface 없음 등) |
| 6 | no such job (suf_collect/check/tail 에서 fifo 없음) |
| 7 | title fuzzy match 결과가 여러 개라 ambiguous |
| 124 | timeout (FIFO read 가 deadline 전에 종료 안 됨) |

## 환경변수

| 변수 | 기본값 | 의미 |
|---|---|---|
| `SUF_V5_PROMPT_MAX` | 500 | prompt 글자 cap |
| `SUF_V5_RESPONSE_MAX` | 4096 | 응답 바이트 cap |
| `SUF_V5_TIMEOUT` | 30 | blocking read 초 |
| `SUF_V5_AUTO_CAP` | on | prompt 끝에 안내문 자동 첨부 (`off` 로 끔) |
| `SUF_V5_FIFO_DIR` | `/tmp/suf-fifo` | FIFO 디렉토리 (mode 0700) |
| `SUF_V5_QUIET` | off | stderr 한 줄 status 표시 (`on` 으로 끔) |
| `SUF_V5_ENTER_DELAY` | 0.15 | send 후 Enter 까지 지연 (초) — race 회피 |
| `SUF_V5_ENTER_DOUBLE` | on | Enter 휘발 보험 위해 한 번 더 송신 (`off` 로 끔) |

### Status line (default 표시)

```
[suf v5] surface:9 (llm) 4s 18B ok
[suf v5] surface:11 (worker) 30s 0B timeout
[suf v5] surface:9 (llm) 12s 4096B ok,truncated
```

`<surface> (<mode>) <elapsed>s <bytes>B <result>`. 호출자가 응답 stdout 만 받고 status 는 stderr 라 파이프라인 안전.

## surface title 자동 매핑

`suf_ask` / `suf_send` / `suf_ask_unsafe` 의 첫 인자는 `surface:9` 같은 ref 또는 cmux surface title 둘 다 가능하다.

```bash
suf_ask "Claude Main" "ping"     # exact title match
suf_send "codex" "task"          # exact 없으면 case-insensitive substring fuzzy match
suf_ask surface:9 "ping"          # 기존 방식도 그대로 동작
```

동작 규칙:
- 첫 인자가 `surface:` 로 시작하면 그대로 사용한다.
- 아니면 `cmux tree --all` 의 surface title 에서 **exact match 우선**, 없으면 **대소문자 무시 substring match**.
- match 0개면 RC=5, 여러 개면 RC=7 과 후보 목록을 stderr 에 출력한다.

## 자동 감지 (LLM vs worker)

`cmux tree` 의 tty → `ps -ww -t <tty> -o args=` 의 process list 매칭:

- **LLM**: claude / codex / gemini / opencode / pi / omc / omo / omx — 이름 또는 argv. anthropic / openai / node-launched 변형 포함
- **Worker**: zsh / bash / sh / fish / dash / ksh / tcsh
- **Unknown** → `suf_ask` reject. `--mode` 로 명시 override

화이트리스트 추가는 `_suf_v5_detect` 함수의 grep 패턴에.

## 한계

- **cross-workspace 미지원** — `cmux send --surface` 가 ref 만 받으므로 현재 workspace 안에서만. (의도된 설계: 다른 ws 의 surface 는 보통 사용자가 사용 중이므로 침범 금지)
- **사용자가 직접 쓰는 sidecar surface 에 worker mode 보내면 입력 충돌** — sidecar 가 사용자 입력 중일 때 cmux send 가 키스트로크로 끼어듦. worker 모드는 사용자 안 보는 surface 에서만.
- **LLM sidecar 가 bypass-permission 모드 아니면 Bash tool 확인 필요** — 그 경우 fifo write 못 함 → timeout. sidecar 의 `--dangerously-skip-permissions` 류 모드 가정.
- **응답 4KB 이상은 truncate** — `suf_ask_unsafe --response-max` 로만 풀림.

## 함정 (v5 도 유효)

- **큰 prompt 보내지 마라** — 자동 reject 되어도 호출자가 그걸 우회하려고 `_unsafe` 쓰는 게 능사 아님. self 가 직접 처리 검토.
- **sidecar 가 fifo write 실패** — TUI LLM 이 Bash 호출 못 했거나 거부. RC=124 timeout. 같은 JOB 재시도 X — fifo 가 이미 unlink 됨. 새 호출.
- **self 에게 send** — 데드락. `suf_other_surfaces` 가 self 제외. surface 직접 지정 시 호출자 책임.
- **`_unsafe` 의 토큰** — cap 풀어도 sidecar 가 큰 본문 생성 = 토큰 폭주. 진짜 의도적일 때만.
- **`suf_check` destructive race** — nonblocking open + close 가 fifo writer 에 SIGPIPE 일으킬 수 있음. check rc=0 직후 collect 가 빈 응답 받는 경우 발생. 진짜 안전한 polling 은 `suf_collect --timeout <짧게>` — kernel blocking read 가 native polling, race 없음. check 는 가벼운 "writer 부착 여부" 신호 정도로만 사용.

## 디버깅

- `_suf_v5_detect surface:N` 호출해서 모드 확인 가능 (private 이지만 source 후 호출됨)
- `SUF_V5_AUTO_CAP=off` 로 안내문 제거하면 sidecar 에 보내는 진짜 prompt 확인 가능
- FIFO 누수 확인: `ls -la /tmp/suf-fifo/`. 정상 종료 시 빈 디렉토리

## v3/v4 마이그레이션

| v3/v4 호출 | v5 대응 |
|---|---|
| `suf_ask <surface> <prompt> [timeout]` | `suf_ask <surface-or-title> <prompt> [--timeout N]` (timeout 인자 위치 변경 + title 지원) |
| `suf_ask_file` | `suf_ask_unsafe --response-max N` 로 통합 (별도 spool 채널 폐기) |
| `suf_send_file` | parent 가 직접 sidecar 의 cwd 에 파일 두고 path 만 inline 전달 권장 |
| `suf_say / suf_wait / suf_hear` | v5 는 단발 blocking. 분리 호출 없음. 비동기 필요하면 v3 fallback |

기존 `suf-lib.sh` (v3) 는 `scripts/` 안에 그대로 두므로 호환 필요한 호출자는 그쪽 source.
