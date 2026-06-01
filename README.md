# cmux-surface-skills

[cmux](https://cmux.run) 환경에서 agent ↔ agent 통신과 일상 개발을 돕는 Claude/Codex/Gemini 공용 스킬 모음. `~/.agents/` 에 두고 `~/.claude/skills/`, `~/.codex/`, `~/.gemini/` 등에서 심볼릭으로 참조하는 글로벌 공유 디렉토리.

## 헤드라인 — `cmux`

cmux sidecar 사이의 짧은 agent-to-agent 통신 스킬. v5는 per-job FIFO 응답 채널을 사용해 sidecar 답변을 blocking read로 받고, LLM/shell worker mode를 자동 감지한다.

```bash
source ~/.agents/skills/cmux/scripts/cmux-v5-lib.sh
ANSWER=$(cmux_ask reviewer "현재 브랜치만 한 줄로")
ANSWER=$(cmux_ask shell "git log -5 --oneline" --mode worker)
```

주요 API:

- `cmux_ask` / `cmux_ask_unsafe` — 동기 ask
- `cmux_send` — 기본 자동 대기·회수
- `cmux_send --no-watch` + `cmux_collect` — 비동기 fire-and-collect
- `cmux_check` — non-blocking probe
- `cmux_tail` — line stream
- `cmux_cancel` — FIFO 정리 + optional ESC
- `cmux_other_surfaces` — 같은 workspace 의 다른 surface 탐색

운영 동작:

- 모든 target resolve는 현재 workspace 안으로 제한된다. pane name 또는 surface title을 우선 사용하고, `surface:N`도 같은 workspace에 있을 때만 허용된다.
- `cmux_collect --timeout N` 이 `rc=124`로 끝나면 FIFO를 보존해 같은 job을 다시 collect 할 수 있다.
- 응답 cap에 걸리면 stdout 본문에는 sentinel을 섞지 않고 stderr status로 노출한다. 함수를 command substitution 없이 같은 셸에서 직접 호출한 경우 `CMUX_V5_LAST_TRUNCATED=1`도 남는다.
- worker mode는 focused/current surface 전송을 기본 차단한다(`CMUX_V5_WORKER_FOCUS_GUARD=off`로 override).

자세한 사용법: [`skills/cmux/SKILL.md`](skills/cmux/SKILL.md), [`skills/cmux/USAGE.md`](skills/cmux/USAGE.md)

## 그 외 스킬

| 스킬 | 설명 |
|---|---|
| `diagnose` | 재현 → 최소화 → 가설 → 계측 → 수정 → 회귀 테스트의 디버깅 루프 |
| `tdd` | TDD 워크플로 (deep modules, interface design, mocking, refactoring) |
| `triage` | 이슈 트리아지 상태 머신 + 역할 기반 라우팅 |
| `to-prd` / `to-issues` | 대화 컨텍스트 → PRD → 독립 실행 가능한 issue 분해 |
| `prototype` | UI/로직 분리 빠른 프로토타이핑 |
| `grill-me` / `grill-with-docs` | 설계 안을 도메인 모델·ADR 에 대고 반복 압박 검증 |
| `improve-codebase-architecture` | CONTEXT.md + ADR 기반 deepening 기회 탐색 |
| `obsidian-manager` | Obsidian vault 양방향 read/write |
| `caveman` | 토큰 ~75% 절감 압축 통신 모드 |
| `find-skills` | 스킬 메타데이터 검색 |
| `write-a-skill` | 새 스킬 작성 가이드 |
| `zoom-out` | 좁아진 시야 리셋 |
| `setup-matt-pocock-skills` | 도메인·이슈 트래킹 부트스트랩 |

## 설치

전체 셋업은 **의존성 1개 + 3단계**.

### 1. cmux 설치

`cmux` 스킬의 필수 의존성.

```bash
brew install cmux   # 또는 https://cmux.run 가이드
```

### 2. Clone (경로 고정)

심볼릭이 상대경로 (`../../.agents/...`) 를 가정하므로 **반드시 `~/.agents`** 로 clone.

```bash
git clone https://github.com/heeza/cmux-surface-skills.git ~/.agents
```

### 3. 에이전트 도구별 노출

#### Claude Code — 원하는 스킬만 (권장)

```bash
mkdir -p ~/.claude/skills
for skill in cmux find-skills caveman; do
  ln -sfn "../../.agents/skills/$skill" "$HOME/.claude/skills/$skill"
done
```

#### Claude Code — 전체 스킬 일괄 노출

```bash
mkdir -p ~/.claude/skills
for skill in ~/.agents/skills/*/; do
  name=$(basename "$skill")
  ln -sfn "../../.agents/skills/$name" "$HOME/.claude/skills/$name"
done
```

#### Codex — AGENTS.md 에 import

```bash
mkdir -p ~/.codex
printf '\n@%s/.agents/skills/cmux/SKILL.md\n' "$HOME" >> ~/.codex/AGENTS.md
```

다른 스킬도 노출하려면 같은 패턴으로 `@$HOME/.agents/skills/<name>/SKILL.md` 라인 추가.

#### Gemini

Gemini CLI 는 별도 스킬 시스템이 없어 자동 노출 안 됨. 필요하면 `~/.gemini/` 설정에서 system prompt 로 `@~/.agents/skills/<name>/SKILL.md` 류 임포트.

## 의존성

- [cmux](https://cmux.run) — `cmux` 스킬 필수
- bash 4+ — `cmux-v5-lib.sh`, legacy `cmux-lib.sh`
- perl — v5 timeout/polling helpers
- shellcheck — CI/static check 용도
- 그 외 스킬은 대부분 self-contained

## 레이아웃

```
~/.agents/
├── rules/
│   └── antigravity-rtk-rules.md
└── skills/
    ├── cmux/
    │   ├── SKILL.md
    │   ├── USAGE.md
    │   └── scripts/
    │       ├── cmux-v5-lib.sh
    │       └── cmux-lib.sh
    ├── diagnose/
    ├── tdd/
    └── ...
```

## 라이선스

개인 사용 목적 — 필요하면 fork 자유롭게.
