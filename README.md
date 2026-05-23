# cmux-surface-skills

[cmux](https://cmux.run) 환경에서 agent ↔ agent 통신과 일상 개발을 돕는 Claude/Codex/Gemini 공용 스킬 모음. `~/.agents/` 에 두고 `~/.claude/skills/`, `~/.codex/`, `~/.gemini/` 등에서 심볼릭으로 참조하는 글로벌 공유 디렉토리.

## 헤드라인 — `suf`

cmux sidecar 와 **마커 + scrollback 폴링** 으로 통신하는 agent-to-agent 프로토콜. 옆 패널의 Claude/Codex/agy/shell 에 질문을 던지고 자연 응답만으로 본문을 추출.

```bash
source ~/.agents/skills/suf/scripts/suf-lib.sh
ANSWER=$(suf_ask surface:4 "현황 보고")
```

한 사이클: **say → wait → hear**

- `say`: 답변 마커 (`<<<SUF_ANSWER:$JOB>>>` ... `<<<SUF_END:$JOB>>>`) 를 동봉해 메시지 송신
- `wait`: scrollback 의 END 마커 등장 횟수 폴링 (`>= 2` 면 sidecar 응답 완료)
- `hear`: 마지막 ANSWER..END 블록만 추출 — prompt echo 블록 자연 폐기

### 왜 scrollback 폴링인가

`cmux wait-for --signal` 기반 ack 방식은 sidecar 가 답변 작성 후 **별도 shell 명령** 을 실행해야 신호가 전달된다. LLM sidecar 가 그 단계를 자주 누락 → 무한 블록. 폴링은 자연 응답만으로 끝난다.

자세한 사용법: [`skills/suf/SKILL.md`](skills/suf/SKILL.md)

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

```bash
git clone https://github.com/heeza/cmux-surface-skills.git ~/.agents

# Claude Code 에서 인식되도록 심볼릭
mkdir -p ~/.claude/skills
for skill in ~/.agents/skills/*/; do
  name=$(basename "$skill")
  ln -sfn "../../.agents/skills/$name" "$HOME/.claude/skills/$name"
done
```

Codex 는 `AGENTS.md` 에서 `~/.agents/` 를 참조하도록 설정.

## 의존성

- [cmux](https://cmux.run) — `suf`, `cmux` 관련 스킬
- bash 4+ — `suf-lib.sh`
- 그 외 스킬은 대부분 self-contained

## 레이아웃

```
~/.agents/
├── rules/
│   └── antigravity-rtk-rules.md
└── skills/
    ├── suf/
    │   ├── SKILL.md
    │   └── scripts/
    │       └── suf-lib.sh
    ├── diagnose/
    ├── tdd/
    └── ...
```

## 라이선스

개인 사용 목적 — 필요하면 fork 자유롭게.
