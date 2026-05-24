---
name: suf
description: cmux sidecar 와 마커 + read-screen 폴링으로 통신하는 agent-to-agent 프로토콜. 옆 패널의 Claude/Codex/agy/shell 에 메시지를 보내고 결과를 받아오기. "/suf", "옆 surface 에 물어봐", "sidecar 와 통신" 트리거. surface 생성 자체는 cmux 스킬, 그 위의 통신 사이클(send → poll → extract)이 suf.
---

# suf — agent ↔ agent 통신

## 두 가지 모드

| 모드 | 용도 | 채널 | 응답 길이 |
|---|---|---|---|
| **inline** (`suf_ask`) | 짧은 텍스트 ack/요약 | screen scrollback | ~수천 줄 (cap) |
| **file** (`suf_ask_file`) | 대용량 본문 (JSON, 로그, 코드, 문서) | `/tmp/suf-spool/<job>.out` + screen 으로 path/size/sha256 | 제한 없음 |

기본은 inline. body 가 클 것 같으면 file 모드. 둘 다 마커 프로토콜은 동일.

## 한 사이클 (v3, inline)

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
| `suf_ask <surface> <prompt> [timeout]` | inline: **say + poll + extract 한 번에**. 99% 이것만. |
| `suf_ask_file <surface> <prompt> [timeout]` | file 모드: sidecar 답변을 spool 파일로 받음. **절대 경로 반환**. 호출자가 cat / 삭제. |
| `suf_send_file <surface> <local-path> <prompt> [timeout]` | parent → sidecar 로 큰 입력 전달. spool 에 복사 후 path+sha 알려주고 inline 답변 수신. |
| `suf_cleanup_spool [<job>]` | spool 정리. 인자 없으면 24h+ 묵은 것 삭제. |
| `suf_say <surface> <prompt>` | 송신만, JOB 반환 (fire-and-forget) |
| `suf_wait <surface> <job> [timeout]` | 닫힌 pair ≥ 2 까지 폴링 |
| `suf_hear <surface> <job>` | 즉시 추출 (대기 없음) |
| `suf_other_surfaces` | self 가 속한 워크스페이스의 다른 surface 목록 |

환경변수:
- `SUF_POLL_INTERVAL` (기본 0.5초) — 폴링 주기
- `SUF_GRACE` (기본 0.5초) — wait 성공 후 extract 전 안정화 대기
- `SUF_READ_LINES` (기본 8000) — read-screen scrollback 라인 수. inline 모드에서만 의미 있음.
- `SUF_SPOOL_DIR` (기본 `/tmp/suf-spool`) — file 모드 spool 위치. mode 0700 으로 자동 생성.

인라인으로 직접 짤 일이 생기면, sidecar 프롬프트는 다음 골격을 따른다:

```
<USER_TASK>

답변은 반드시 아래 두 마커 사이에만 작성:
<<<SUF_ANSWER:$JOB>>>
(답변 본문)
<<<SUF_END:$JOB>>>
```

별도 ack 명령 불필요 — sidecar 가 마커 사이에 답만 쓰면 끝.

## file 모드 디테일

```bash
source ~/.agents/skills/suf/scripts/suf-lib.sh

# 대용량 답변 받기
path=$(suf_ask_file surface:22 "전체 로그 줘") || exit 1
wc -l "$path"; head -100 "$path"
rm -f "$path"

# 대용량 입력 보내기
text_answer=$(suf_send_file surface:22 ./big-input.json "이거 분석해줘")
```

### 마커 안 페이로드 (file 모드)

```
<<<SUF_ANSWER:$job>>>
SUF_FILE: /tmp/suf-spool/<job>.out
SUF_SIZE: 12345
SUF_SHA256: abc123...
<<<SUF_END:$job>>>
```

parent 측 검증: 파일 존재 → `wc -c` 와 `SUF_SIZE` 일치 → `shasum -a 256` 와 `SUF_SHA256` 일치. 어느 하나 어긋나면 exit 코드 2/3/4 로 실패.

### sidecar 가 받는 instruction

`suf_ask_file` 은 prompt 끝에 **shell 한 줄 그대로 복붙 가능한 템플릿**을 붙임:

```bash
cat > /tmp/suf-spool/<job>.out.tmp <<'EOF_SUF_BODY'
(여기에 답변 본문)
EOF_SUF_BODY
mv ...tmp ...out && \
  printf '<<<SUF_ANSWER:%s>>>\nSUF_FILE: %s\nSUF_SIZE: %s\nSUF_SHA256: %s\n<<<SUF_END:%s>>>\n' ...
```

sidecar 가 Claude/Codex 라면 Bash 툴로 실행. 일반 shell 이면 그대로 paste. atomic rename 으로 parent 가 부분쓰기 파일을 잡는 race 방지.

## v1 → v4 개선점 요약

| 항목 | v1 | v3 | v4 |
|---|---|---|---|
| 매칭 모델 | END 횟수 ≥ 2 (열린 END 도 카운트) | **닫힌 ANSWER..END pair ≥ 2** | (v3 유지) |
| scrollback 한계 | 4000줄 | 8000줄 (`SUF_READ_LINES`) | inline 은 동일, **file 모드는 무관** |
| polling 주기 | 1초 | 0.5초 | (v3 유지) |
| job 충돌 | `ns-PID` | `ns-PID-urandom4hex` | (v3 유지) |
| 대용량 payload | screen cap 에 묶임 | 동일 | **`/tmp/suf-spool/` 파일 채널 + size+sha256 검증** |
| input 대용량 | 입력창 길이 의존 | 동일 | **`suf_send_file` 로 file path 전달** |

## 함정

- **send-key Enter 누락** — 입력만 들어가고 실행 안 됨. `suf_say` 가 자동 처리.
- **self 에게 send** — 데드락. `suf_other_surfaces` / `$CMUX_SURFACE_ID` 로 self 배제. 같은 함수가 **다른 워크스페이스의 surface 도 자동 제외**한다.
- **사용자 surface 를 close** — 금지. 부모가 만든 sidecar 만 정리.
- **sidecar 가 마커 빠뜨림** — closed pair 1개 (echo) 에서 멈춰 timeout. 프롬프트에 마커 사용 지시가 명확해야 함.
- **응답 매우 길어 scrollback 밖으로 밀림** — inline 의 본질적 한계. **`suf_ask_file` 로 전환**. `SUF_READ_LINES=20000` 식 임시 조치도 가능하지만 파일 모드가 정답.
- **TUI 가 아닌 일반 shell** — pair 카운팅 동일하게 작동. shell echo 가 raw text 라 closed pair 1 + 응답 1 = 2 로 자연 일치.
- **file 모드에서 sidecar 가 본문을 inline 으로 출력** — SUF_FILE 라인 없는 pair 라 timeout. prompt 가 충분히 명확해도 일부 sidecar 가 file write 거부할 수 있음. 그 경우 `suf_ask` 로 대체.
- **size/sha256 mismatch (exit 3/4)** — sidecar 가 mv 전에 메타를 계산했거나 파일이 중간에 덮어쓰임. 같은 JOB 재시도하지 말고 새 JOB 으로 다시 호출.
- **spool 누수** — file 모드 호출자가 명시적으로 `rm` 안 하면 24h 후 `suf_cleanup_spool` 이 청소. 민감 데이터면 호출 직후 삭제.

## 확장 — fan-in / 진척 보고

다중 sidecar 동시 처리나 중간 진척 알림이 필요하면 `cmux events --category notification` + sidecar 의 `cmux notify` 결합. 단순 1:1 ask 엔 불필요.

## 안 쓰는 경우

- 패널만 열면 충분 → cmux 스킬
- 응답을 사용자가 직접 보면 되는 경우 → ack 불필요
- ack 불가능한 TUI (vim, k9s, btop) — 마커 echo 자체가 안 되므로 화면 안정 감지 fallback 필요
