---
name: cmux
description: cmux sidecar 사이의 짧은 agent-to-agent 통신. v5는 per-job FIFO 응답 채널과 자동 모드 감지(LLM|worker)를 사용한다. 짧은 ack/조회/단일 명령 위임에만 사용하고 큰 작업 위임은 금지한다.
---

# cmux v5 (v5.2 고성능/고신뢰성 패치 적용)

- **Perl 기반 Event-Loop**: dynamic read 시 매초 fork하던 오버헤드를 O(1)로 줄였습니다.
- **Non-destructive Check**: `cmux_check`가 FIFO를 직접 열지 않고 `lsof`를 통해 writer 존재를 파악해 `SIGPIPE` 레이스를 원천 차단했습니다.
- **Persistent Tail**: `cmux_tail`이 여러 차례 `>>`로 쪼개서 스트림을 쓰는 경우에도 끊어지지 않고 sidecar의 작업 완료 시까지 추적합니다.
- **설정형 TTL 캐시**: `cmux tree`를 `CMUX_V5_TREE_TTL`(기본 3초) 동안 캐싱하여, 한 요청 내 resolve→detect→read 가 tree 를 재호출하지 않습니다.
- **병렬 fan-in**: 무타겟 `cmux_collect`(전체 pending 회수)가 각 job 을 병렬 수집합니다. 총 대기시간이 합(sum)이 아니라 최댓값(max)이며, 자기가 띄운 collector 만 `wait` 하여 무관한 잡에 묶이지 않습니다.
- **`cmux_broadcast` fan-out/fan-in**: 동일 prompt 를 여러 LLM surface 에 동시 질의하고 병렬 수신합니다. 응답은 surface 당 캡(토큰 bound), 1-shot 이라 무한 토큰 소요가 없습니다.
- **`cmux_cross` 복구**: 라운드마다 직전 답변을 임베드할 때 `PROMPT_MAX(500)` 캡에 걸려 중단되던 문제를 해소하고, 응답을 `CMUX_V5_CROSS_RESPONSE_MAX`(기본 16384B)로 캡하여 라운드 누적 토큰을 bound 합니다.
- **빈 응답 즉시 종료**: side-effect-only worker 명령·no-match·빈 답변(0바이트) 이 timeout 까지 hang 되지 않고 즉시 `rc=0` 으로 반환됩니다.

## 원칙

- 짧은 질문, 상태 확인, 단일 shell command 위임에만 사용한다.
- 리포트, 긴 분석, 긴 코드/문서 작성은 parent가 직접 처리한다. sidecar 위임은 토큰이 더 든다.
- 기본 경로는 FIFO only다. screen fallback은 token/noise 비용 때문에 opt-in이다.
- `cmux_send`는 비동기 시작만 한다. 결과는 `cmux_collect`로 받는다.

## 사용

```bash
source ~/.agents/skills/cmux/scripts/cmux-v5-lib.sh
```

동기:

```bash
ANSWER=$(cmux_ask surface:9 "현재 브랜치만 한 줄로")
ANSWER=$(cmux_ask "codex" "git log -5 --oneline" --mode worker)
ANSWER=$(cmux_ask_unsafe "codex" "$LONG" --prompt-max 4000 --response-max 65536 --timeout 180)
```

비동기:

```bash
job=$(cmux_send "codex" "build 끝나면 한 줄 요약")
cmux_collect "$job" --timeout 600
```

여러 에이전트에 동시 질의 (fan-out → 병렬 fan-in):

```bash
# 대상 지정
cmux_broadcast "현재 브랜치만 한 줄로" "codex" "minimax" "agy"
# 대상 생략 시 같은 workspace 의 다른 LLM surface 전체
cmux_broadcast "한 줄 상태 보고" --timeout 120
```

현재 workspace의 다른 surface:

```bash
cmux_other_surfaces
```

## API

| 함수 | 용도 |
|---|---|
| `cmux_ask <surface|title> <prompt> [--mode llm|worker] [--timeout N]` | 동기 요청. 기본 cap 적용 |
| `cmux_ask_unsafe <surface|title> <prompt> [opts]` | 큰 prompt/response 의도 시 사용 |
| `cmux_send <surface|title> <prompt> [--mode llm|worker]` | 비동기 시작. stdout은 job id |
| `cmux_collect [job|surface|title] [--timeout N] [--response-max N]` | pending job 결과 수집 |
| `cmux_tail <job> [--timeout N]` | FIFO raw tail |
| `cmux_cancel <job> [--esc]` | FIFO 삭제, optional ESC |
| `cmux_check [job|surface|title]` | 가벼운 pending 확인. 결과 polling에는 `cmux_collect --timeout <짧게>` 권장 |
| `cmux_cross <target> [analyzer] <prompt> [--rounds N]` | 교차 검토 및 피드백 토론 오케스트레이션 (3회 반복 디폴트). 응답은 `CMUX_V5_CROSS_RESPONSE_MAX`로 캡 |
| `cmux_broadcast <prompt> [target ...] [--mode m] [--timeout N] [--response-max N]` | 동일 prompt 를 여러 LLM surface 에 fan-out 후 병렬 fan-in. 대상 생략 시 같은 workspace 의 다른 LLM 전체. 1-shot·응답 캡으로 토큰 bound |

`surface` 인자는 `surface:N` 또는 title을 받는다. title 다중 매치 시 첫 번째를 쓴다.

## 기본값

| env | default | 의미 |
|---|---:|---|
| `CMUX_V5_PROMPT_MAX` | 500 | prompt 글자 cap |
| `CMUX_V5_RESPONSE_MAX` | 4096 | 응답 바이트 cap |
| `CMUX_V5_TIMEOUT` | 1200 | FIFO blocking read 초 (20분) |
| `CMUX_V5_AUTO_CAP` | on | LLM 수신 규칙 자동 첨부 |
| `CMUX_V5_TREE_TTL` | 3 | `cmux tree` 캐시 TTL(초). resolve→detect→read 간 fork 재사용 |
| `CMUX_V5_CROSS_RESPONSE_MAX` | 16384 | `cmux_cross` 라운드별 응답 바이트 캡 (토큰 bound) |
| `CMUX_V5_PROMPT_STYLE` | compact | `compact|verbose` |
| `CMUX_V5_FALLBACK_SCREEN` | off | `cmux read-screen` marker fallback opt-in |
| `CMUX_V5_SCREEN_LINES` | 200 | screen fallback 라인 수 |
| `CMUX_V5_EARLY_IDLE` | off | `off|worker|llm|on`; 실패 조기 감지 polling |
| `CMUX_V5_POLL_INTERVAL` | 1 | early-idle polling 간격 |
| `CMUX_V5_FIFO_DIR` | `/tmp/cmux-fifo` | FIFO 디렉토리 |
| `CMUX_V5_QUIET` | off | stderr status 숨김 |
| `CMUX_V5_ENTER_DELAY` | 0.15 | send 후 Enter 지연 |
| `CMUX_V5_ENTER_DOUBLE` | on | Enter 재송신 보험 |

## Mode

자동 감지:

- `claude`, `codex`, `gemini`, `pi` 등이 보이면 `llm`
- shell만 보이면 `worker`
- 실패하면 `--mode llm|worker`를 명시한다

Worker mode는 사용자가 직접 입력 중인 surface에 보내지 않는다. PTY에 키스트로크가 주입된다.

## Fallback

기본은 FIFO only다. LLM sidecar가 Bash/tool 호출을 못 하는 환경이면 필요할 때만 켠다:

```bash
CMUX_V5_FALLBACK_SCREEN=on cmux_ask surface:9 "한 줄 답"
```

fallback을 켜면 prompt에 marker 지시가 추가되고, 실패 시 `cmux read-screen`으로 마커 사이 답을 추출한다. 토큰과 screen noise가 늘어난다.

## 문제 해결

- prompt가 너무 크면 `cmux_ask_unsafe --prompt-max N`을 쓴다.
- 응답이 잘리면 `--response-max N`을 올린다.
- 모드 감지 실패는 `--mode llm` 또는 `--mode worker`로 해결한다.
- 전송 race가 보이면 `CMUX_V5_ENTER_DELAY`를 조금 올리거나 `CMUX_V5_ENTER_DOUBLE=on`을 유지한다.
- 실패를 timeout까지 기다리기 싫으면 `CMUX_V5_EARLY_IDLE=worker` 또는 `on`을 쓴다.

## 호환

v3 `cmux-lib.sh`는 `scripts/`에 남아 있다. v5 신규 호출은 `cmux-v5-lib.sh`를 사용한다.
