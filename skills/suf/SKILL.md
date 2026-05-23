---
name: suf
description: cmux sidecar 와 마커 + scrollback 폴링으로 통신하는 agent-to-agent 프로토콜. 옆 패널의 Claude/Codex/agy/shell 에 메시지를 보내고 결과를 받아오기. "/suf", "옆 surface 에 물어봐", "sidecar 와 통신" 트리거. surface 생성 자체는 cmux 스킬, 그 위의 통신 사이클(send → poll → extract)이 suf.
---

# suf — agent ↔ agent 통신

## 한 사이클

```
say → wait → hear
```

- **say**: 본문 마커 포함해서 메시지 송신
- **wait**: scrollback 의 END 마커 등장 횟수 폴링 (>=2 면 sidecar 응답 완료)
- **hear**: scrollback 에서 **마지막** ANSWER..END 블록만 추출 (prompt echo 제외)

surface 가 새로 필요하면 앞에 `cmux new-split`, 부모가 만든 sidecar 면 마지막에 `cmux close-surface`.

## 왜 폴링인가

`cmux send` 가 prompt 를 target surface 의 scrollback 에 1회 echo 한다 (입력 chip 으로 보임). 그래서 END 마커는:
- **send 직후**: 1회 (prompt echo)
- **sidecar 응답 완료**: 2회 (prompt echo + real answer)

신호 기반(`cmux wait-for --signal`) 은 sidecar 가 답변 작성 후 별도 shell 명령을 실행해야 하는데, LLM 이 그 단계를 건너뛰면 영원히 블록된다. 폴링은 자연 응답만으로 끝난다.

## 마커

`<<<SUF_ANSWER:$JOB>>>` ... `<<<SUF_END:$JOB>>>`

JOB 은 nanosecond timestamp + PID — 매 호출 고유.

## 권장 사용 — 헬퍼 한 줄

```bash
source ~/.agents/skills/suf/scripts/suf-lib.sh
ANSWER=$(suf_ask surface:22 "현황 보고")
```

| 함수 | 역할 |
|---|---|
| `suf_ask <surface> <prompt> [timeout]` | say + wait + hear 한 번에 (가장 흔함) |
| `suf_say <surface> <prompt>` | 송신만, JOB 반환 |
| `suf_wait <surface> <job> [timeout]` | END 마커 >=2 까지 폴링 (기본 600s) |
| `suf_hear <surface> <job>` | 마지막 ANSWER..END 블록 추출 |
| `suf_other_surfaces` | self 의 **같은 워크스페이스 내** 다른 surface 목록 (타 워크스페이스 자동 제외) |

환경변수:
- `SUF_POLL_INTERVAL` (기본 1초) — 폴링 주기
- `SUF_GRACE` (기본 0.5초) — wait 성공 후 hear 전 안정화 대기

인라인으로 직접 짤 일이 생기면, sidecar 프롬프트는 다음 골격을 따른다:

```
<USER_TASK>

답변은 반드시 아래 두 마커 사이에만 작성:
<<<SUF_ANSWER:$JOB>>>
(답변 본문)
<<<SUF_END:$JOB>>>
```

별도 ack 명령 불필요 — sidecar 가 마커 사이에 답만 쓰면 끝.

## 함정

- **scrollback 작음** → 답변 잘림. 4000 줄 default.
- **send-key Enter 누락** → 입력만 들어가고 실행 안 됨. `send` 직후 항상 Enter.
- **self 에게 send** → 데드락. `suf_other_surfaces` / `$CMUX_SURFACE_ID` 로 self 배제. 같은 함수가 **다른 워크스페이스의 surface 도 자동 제외**한다 — 워크스페이스는 분리된 작업 컨텍스트이므로 cross-ws 의사전달은 금지.
- **사용자 surface 를 close** → 금지. 부모가 만든 sidecar 만 정리.
- **prompt echo 카운팅** — `suf_wait` 는 END 마커가 2회 이상 나타나야 완료로 판정. send echo (1회) + 응답 (1회). sidecar 가 마커를 빠뜨리고 답만 쓰면 카운트 1 에서 멈춰 timeout. 프롬프트에 마커 사용 지시가 명확해야 함.
- **마커 중복 응답** — sidecar 가 마커를 응답 본문 안에 재인용하면 END 가 3회+ 가 될 수 있음. `suf_hear` 는 **마지막 블록**만 반환하므로 보통 안전.

## 확장 — fan-in / 진척 보고

다중 sidecar 동시 처리나 중간 진척 알림이 필요하면 `cmux events --category notification` + sidecar 의 `cmux notify` 결합. 단순 1:1 ask 엔 불필요.

## 안 쓰는 경우

- 패널만 열면 충분 → cmux 스킬
- 응답을 사용자가 직접 보면 되는 경우 → ack 불필요
- ack 불가능한 TUI (vim, k9s, btop) → 화면 안정 감지 fallback
