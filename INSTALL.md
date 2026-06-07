# 설치 매뉴얼 — 다른 Mac PC

cmux-surface-skills (`cmux` v5 포함) 를 새로운 macOS 머신에 처음 설치하는 절차.

소요 시간: **5~10분**. 의존성 1개 (cmux) + 디렉토리 clone + LLM CLI 별 심볼릭.

---

## 0. 전제 조건

| 도구 | 필수? | 확인 |
|---|---|---|
| **macOS** | 필수 | `sw_vers` |
| **bash 또는 zsh** | 필수 | 둘 다 기본 |
| **perl** | 필수 (v5 의 timeout/sysread 핵심) | `perl -v` — macOS 기본 |
| **git** | 필수 | `git --version` — Xcode CLT 또는 brew |
| **cmux** | cmux 스킬에 필수 | `cmux version` |
| **awk, ps, mkfifo** | 필수 (모두 BSD 기본) | 자동 존재 |
| Claude Code | 사용 시 | `claude --version` |
| Codex CLI | 사용 시 | `codex --version` |
| Gemini CLI | 사용 시 | `gemini --version` |
| Junie | 사용 시 | (JetBrains IDE 통합) |

cmux 미설치 시:

```bash
# Homebrew 가 깔려 있다고 가정
brew install cmux
# 또는 https://cmux.run 의 공식 가이드
```

---

## 1. 저장소 clone — **경로 고정**

심볼릭이 상대경로 (`../../.agents/...`) 를 가정하므로 **반드시 `~/.agents`** 로 clone.

```bash
# 기존 ~/.agents 가 있으면 백업
[ -d ~/.agents ] && mv ~/.agents ~/.agents.bak.$(date +%s)

git clone https://github.com/heeza/cmux-surface-skills.git ~/.agents
```

검증:

```bash
ls ~/.agents/skills/cmux/scripts/
# 다음 두 파일이 보여야 함:
#   cmux-lib.sh         (v3/v4 fallback)
#   cmux-v5-lib.sh      (v5, 권장)
```

---

## 2. LLM CLI 별 노출

### 2a. Claude Code

**cmux 만 노출 (권장):**

```bash
mkdir -p ~/.claude/skills
ln -sfn "../../.agents/skills/cmux" "$HOME/.claude/skills/cmux"
```

**전체 스킬 일괄:**

```bash
mkdir -p ~/.claude/skills
for skill in ~/.agents/skills/*/; do
  name=$(basename "$skill")
  ln -sfn "../../.agents/skills/$name" "$HOME/.claude/skills/$name"
done
```

검증:

```bash
ls -la ~/.claude/skills/cmux
# 출력에 화살표 (->) 가 있으면 심볼릭 OK
# 예: cmux -> ../../.agents/skills/cmux
```

### 2b. Gemini CLI

```bash
mkdir -p ~/.gemini/skills
ln -sfn "../../.agents/skills/cmux" "$HOME/.gemini/skills/cmux"
```

(Gemini 가 스킬 자동 로드 안 하면 GEMINI.md 에 `@~/.agents/skills/cmux/SKILL.md` 추가)

### 2c. Junie (JetBrains)

```bash
mkdir -p ~/.junie/skills
ln -sfn "../../.agents/skills/cmux" "$HOME/.junie/skills/cmux"
```

### 2d. Codex — AGENTS.md import

```bash
mkdir -p ~/.codex
printf '\n@%s/.agents/skills/cmux/SKILL.md\n' "$HOME" >> ~/.codex/AGENTS.md
```

다른 스킬 추가는 동일 패턴:

```bash
printf '@%s/.agents/skills/diagnose/SKILL.md\n' "$HOME" >> ~/.codex/AGENTS.md
```

---

## 3. v5 lib 작동 검증

저장소 clone 직후에는 먼저 전체 로컬 게이트를 실행합니다.

```bash
cd ~/.agents
make check
```

`make check`는 `scripts/doctor`, Bash/zsh syntax, zsh source smoke, ShellCheck(설치된 경우), `tests/cmux-v5-lib-test.sh`를 순서대로 실행합니다.

```bash
bash -c '
  source ~/.agents/skills/cmux/scripts/cmux-v5-lib.sh

  echo "=== 1) public 함수 확인 ==="
  declare -F | grep -E "cmux_(ask|flow|trace|metrics|other)"
  # 적어도 다음 함수들이 보여야 함:
  #   cmux_ask
  #   cmux_ask_unsafe
  #   cmux_flow
  #   cmux_trace
  #   cmux_metrics
  #   cmux_other_surfaces

  echo "=== 2) cap 기본값 확인 ==="
  echo "PROMPT_MAX=$CMUX_V5_PROMPT_MAX (기본 500)"
  echo "RESPONSE_MAX=$CMUX_V5_RESPONSE_MAX (기본 4096)"
  echo "TIMEOUT=$CMUX_V5_TIMEOUT (기본 1200)"

  echo "=== 3) cap 강제 reject 확인 ==="
  long=$(printf "a%.0s" $(seq 1 600))
  cmux_ask surface:1 "$long" 2>&1 >/dev/null
  echo "exit code: $? (2 면 정상)"
'
```

기대 결과: 핵심 public 함수들이 보임 + cap 값 출력 + reject 시 exit 2.

---

## 4. cmux 환경에서 실제 ping

cmux 가 실행 중이고 옆 surface 에 Claude/Codex 등 LLM 이 떠 있어야 함.

```bash
# 현재 surface 목록 확인
cmux tree --all

# 같은 workspace 의 다른 surface 식별 (예: surface:9 가 LLM)
source ~/.agents/skills/cmux/scripts/cmux-v5-lib.sh
cmux_ask surface:9 "현재 한국 시간만 한 줄로"
```

기대 결과: 5~10초 안에 한 줄 답변 출력.

실패 시 [트러블슈팅](#5-트러블슈팅) 참조.

---

## 5. 트러블슈팅

### `cmux: command not found`

cmux 설치 안 됨 — 위의 0번 항목으로.

### `Error: invalid_params: Surface is not a terminal`

surface ref 가 다른 workspace 를 가리킴 (v5 는 cross-workspace 미지원). 같은 workspace 의 surface 만 사용.

### `[cmux v5] cannot auto-detect sidecar on surface:X`

sidecar 의 프로세스가 화이트리스트 (claude/codex/gemini/zsh/bash 등) 에 없음. 명시 mode 로 우회:

```bash
cmux_ask surface:X "..." --mode llm     # LLM TUI 면
cmux_ask surface:X "date" --mode worker # shell 이면
```

### `RC=124` (timeout)

sidecar 가 FIFO write 를 못 함. 흔한 원인:

1. **LLM 의 Bash tool permission 미허용** — Claude Code 의 `⏵⏵ bypass permissions on` 같은 모드 필요
2. **prompt 가 너무 무거워서 sidecar 가 본문 생성에 오래 걸림** — 더 짧은 prompt 로 재시도
3. **sidecar 가 마커 / fifo 안내문을 무시함** — `CMUX_V5_AUTO_CAP=on` 인지 확인

### `prompt size N > PROMPT_MAX=500`

cap reject. 의도적이면:

```bash
cmux_ask_unsafe surface:9 "$LONG" --prompt-max 4000 --response-max 65536
```

단 sidecar 의 토큰 비용이 함께 큼. self 가 직접 처리 검토 권장.

### perl 미설치 (드물지만 minimal macOS)

```bash
brew install perl
```

### FIFO 누수 의심

```bash
ls -la /tmp/cmux-fifo/
# 정상 종료 시 비어 있어야 함. 잔여 fifo:
rm -f /tmp/cmux-fifo/*.res
```

---

## 6. v5 환경변수 (선택)

`~/.zshrc` 또는 `~/.bashrc` 에 추가:

```bash
# 더 엄격한 cap 원할 때
export CMUX_V5_PROMPT_MAX=300
export CMUX_V5_RESPONSE_MAX=2048
export CMUX_V5_TIMEOUT=20

# 자동 cap 안내문 끄고 raw prompt 만 보내기 (디버깅)
export CMUX_V5_AUTO_CAP=off

# FIFO 위치 변경
export CMUX_V5_FIFO_DIR=/tmp/my-cmux

# stderr 한 줄 status 끄고 응답 본문만 받기 (script 출력용)
export CMUX_V5_QUIET=on

# Enter race 더 보수적으로 (느린 머신 / 무거운 sidecar)
export CMUX_V5_ENTER_DELAY=0.3
```

---

## 7. 업데이트

```bash
cd ~/.agents
git pull
```

심볼릭은 그대로라 변경 자동 반영. `cmux-v5-lib.sh` 만 바뀌면 호출자가 `source` 만 새로 하면 즉시 적용. SKILL.md 가 바뀌면 LLM CLI 재시작 후 새 description 반영.

---

## 8. 제거

```bash
# 심볼릭 제거
rm -f ~/.claude/skills/cmux ~/.gemini/skills/cmux ~/.junie/skills/cmux

# codex AGENTS.md 의 cmux 라인 수동 삭제
$EDITOR ~/.codex/AGENTS.md

# 본체 제거
rm -rf ~/.agents

# 잔여 fifo
rm -rf /tmp/cmux-fifo
```

---

## 부록 — 최소 설치 (cmux 만, claude only)

```bash
brew install cmux
git clone https://github.com/heeza/cmux-surface-skills.git ~/.agents
mkdir -p ~/.claude/skills
ln -sfn "../../.agents/skills/cmux" "$HOME/.claude/skills/cmux"
# 검증
source ~/.agents/skills/cmux/scripts/cmux-v5-lib.sh
declare -F cmux_ask
```

3줄로 완료.
