#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-v5-tests.XXXXXX")"
STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$STUB_DIR/cmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  tree)
    printf '%s\n' "${CMUX_TEST_TREE:-}"
    ;;
  read-screen)
    printf '%s\n' "${CMUX_TEST_SCREEN:-}"
    ;;
  send)
    if [ -n "${CMUX_TEST_SEND_WRITE:-}" ]; then
      ans="$(printf '%s\n' "$@" | grep -oE '/[^ ]+\.ans' | head -1)"
      if [ -n "$ans" ]; then
        (
          sleep "${CMUX_TEST_SEND_DELAY:-0}"
          printf '%s' "$CMUX_TEST_SEND_WRITE" > "$ans.tmp"
          mv -f "$ans.tmp" "$ans"
        ) &
      fi
    fi
    exit 0
    ;;
  send-key)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$STUB_DIR/cmux"

export PATH="$STUB_DIR:$PATH"
export CMUX_V5_FIFO_DIR="$TMP_ROOT/fifo"
export CMUX_V5_LOCK_DIR="$TMP_ROOT/locks"
export CMUX_V5_JOB_DIR="$TMP_ROOT/jobs"
export CMUX_V5_LOCK_WAIT=10
export CMUX_V5_LOCK_TTL=30
export CMUX_V5_QUIET=on
export CMUX_V5_TREE_TTL=0
export CMUX_V5_FALLBACK_SCREEN=off

# shellcheck source=/dev/null
source "$ROOT/skills/cmux/scripts/cmux-v5-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_fifo() {
  local name="$1" fifo
  mkdir -p "$CMUX_V5_FIFO_DIR"
  fifo="$CMUX_V5_FIFO_DIR/$name.res"
  rm -f "$fifo"
  mkfifo "$fifo"
  printf '%s' "$fifo"
}

reset_job_state() {
  rm -rf "$CMUX_V5_JOB_DIR" "$CMUX_V5_LOCK_DIR"
  mkdir -p "$CMUX_V5_JOB_DIR" "$CMUX_V5_LOCK_DIR"
  _CMUX_V5_JOBGC_DONE=0
}

test_collect_timeout_preserves_fifo() {
  local fifo rc writer
  fifo="$(make_fifo "job-timeout")"
  (
    exec 3>"$fifo"
    sleep 3
  ) &
  writer=$!

  set +e
  cmux_collect "job-timeout" --timeout 1 >/dev/null 2>&1
  rc=$?
  set -e
  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true

  [ "$rc" -eq 124 ] || fail "collect timeout returned rc=$rc, expected 124"
  [ -p "$fifo" ] || fail "collect timeout removed FIFO"
  rm -f "$fifo"
  pass "collect timeout preserves FIFO for polling"
}

test_collect_success_unlinks_fifo() {
  local fifo ans out
  fifo="$(make_fifo "job-success")"
  ans="${fifo%.res}.ans"
  (
    printf 'done' > "$ans.tmp"
    mv -f "$ans.tmp" "$ans"
  ) &

  out="$(cmux_collect "job-success" --timeout 3 2>/dev/null)"
  wait 2>/dev/null || true

  [ "$out" = "done" ] || fail "collect output was '$out'"
  [ ! -e "$fifo" ] || fail "successful collect left FIFO behind"
  pass "successful collect unlinks FIFO"
}

test_truncation_metadata_is_out_of_band() {
  local fifo out rc
  fifo="$(make_fifo "job-truncate")"
  (
    printf 'abcdef' > "$fifo"
  ) &

  set +e
  _cmux_v5_read_fifo_dynamic "$fifo" "" "" 3 3 > "$TMP_ROOT/truncated.out"
  rc=$?
  set -e
  wait 2>/dev/null || true
  out="$(cat "$TMP_ROOT/truncated.out")"
  rm -f "$fifo"

  [ "$rc" -eq 0 ] || fail "truncate read returned rc=$rc"
  [ "$out" = "abc" ] || fail "truncate output was '$out'"
  [ "${CMUX_V5_LAST_TRUNCATED:-0}" = "1" ] || fail "truncate metadata flag not set"
  case "$out" in
    *CMUX_TRUNCATED*) fail "truncate marker leaked into stdout" ;;
  esac
  pass "truncation is exposed out-of-band"
}

test_truncation_keeps_utf8_boundary() {
  local fifo out rc
  fifo="$(make_fifo "job-truncate-utf8")"
  (
    printf '가나다' > "$fifo"
  ) &

  set +e
  _cmux_v5_read_fifo_dynamic "$fifo" "" "" 3 4 > "$TMP_ROOT/truncated-utf8.out"
  rc=$?
  set -e
  wait 2>/dev/null || true
  out="$(cat "$TMP_ROOT/truncated-utf8.out")"
  rm -f "$fifo"

  [ "$rc" -eq 0 ] || fail "utf8 truncate read returned rc=$rc"
  [ "$out" = "가" ] || fail "utf8 truncate output was '$out'"
  [ "${CMUX_V5_LAST_TRUNCATED:-0}" = "1" ] || fail "utf8 truncate metadata flag not set"
  pass "truncation preserves UTF-8 boundary"
}

test_worker_focus_guard_blocks_active_surface() {
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    └── pane pane:1 [focused] ◀ active
        └── surface surface:9 [terminal] "zsh" [selected] ◀ active ◀ here tty=ttys001'
  export CMUX_TEST_SCREEN='/tmp/repo
❯ '
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  set +e
  _cmux_v5_worker_send_guard "surface:9" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 7 ] || fail "worker focus guard returned rc=$rc, expected 7"
  pass "worker focus guard blocks active surface"
}

test_cmux_send_worker_guard_blocks_before_fifo() {
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    └── pane pane:1 [focused] ◀ active
        └── surface surface:9 [terminal] "zsh" [selected] ◀ active ◀ here tty=ttys001'
  export CMUX_TEST_SCREEN='/tmp/repo
❯ '
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  set +e
  cmux_send "surface:9" "date" --mode worker >/dev/null 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 7 ] || fail "cmux_send worker guard returned rc=$rc, expected 7"
  [ ! -d "$CMUX_V5_FIFO_DIR" ] || [ -z "$(find "$CMUX_V5_FIFO_DIR" -type p -print -quit 2>/dev/null)" ] || fail "guard created a FIFO before refusing"
  pass "cmux_send worker guard blocks before FIFO creation"
}

test_worker_focus_guard_allows_inactive_surface() {
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
    └── pane pane:2
        └── surface surface:9 [terminal] "zsh" [selected] tty=ttys002'
  export CMUX_TEST_SCREEN='/tmp/repo
❯ '
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  _cmux_v5_worker_send_guard "surface:9" 2>/dev/null || fail "worker focus guard blocked inactive surface"
  pass "worker focus guard allows inactive surface"
}

test_resolve_accepts_pane_name_in_current_workspace() {
  local resolved
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
    └── pane pane:2 "reviewer"
        └── surface surface:9 [terminal] "claudee" [selected] tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  resolved="$(_cmux_v5_resolve "reviewer")"
  [ "$resolved" = "surface:9" ] || fail "pane name resolved to '$resolved'"
  pass "pane name resolves to surface in current workspace"
}

test_resolve_prefers_surface_title_over_pane_title() {
  local resolved
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 "agy"
    │   └── surface surface:8 [terminal] "codex" [selected] tty=ttys008
    └── pane pane:2 [focused] ◀ active
        └── surface surface:9 [terminal] "agy" [selected] ◀ active ◀ here tty=ttys009'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  resolved="$(_cmux_v5_resolve "agy")"
  [ "$resolved" = "surface:9" ] || fail "surface title did not beat pane title, resolved '$resolved'"
  pass "surface title takes precedence over pane title"
}

test_resolve_duplicate_surface_titles_warn_and_pick_lowest() {
  local rc resolved
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
    ├── pane pane:2
    │   └── surface surface:9 [terminal] "agy" [selected] tty=ttys009
    └── pane pane:3
        └── surface surface:8 [terminal] "agy" [selected] tty=ttys008'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  set +e
  resolved="$(_cmux_v5_resolve "agy" 2>/dev/null)"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "duplicate surface titles resolved with rc=$rc, expected 0"
  # tree 등장 순서가 9,8 이어도 숫자상 lowest 인 surface:8 을 골라야 한다.
  [ "$resolved" = "surface:8" ] || fail "duplicate titles resolved to '$resolved', want surface:8"
  pass "duplicate surface titles warn and pick numerically lowest"
}

test_surface_title_matches_exact_surface_id() {
  local title
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1
    │   └── surface surface:10 [terminal] "ten" [selected] tty=ttys010
    └── pane pane:2 [focused] ◀ active
        └── surface surface:1 [terminal] "one" [selected] ◀ active ◀ here tty=ttys001'
  _CMUX_V5_TREE_CACHE=""
  _CMUX_V5_TREE_CACHE_TIME=0

  title="$(_cmux_v5_surface_title "surface:1")"
  [ "$title" = "one" ] || fail "surface:1 title matched '$title'"
  pass "surface title lookup matches exact surface id"
}

test_resolve_rejects_surface_outside_current_workspace() {
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
├── workspace workspace:1 "current" [selected] ◀ active
│   └── pane pane:1 [focused] ◀ active
│       └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
└── workspace workspace:2 "other"
    └── pane pane:2 "reviewer"
        └── surface surface:9 [terminal] "claudee" [selected] tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  set +e
  _cmux_v5_resolve "surface:9" >/dev/null 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 6 ] || fail "outside surface resolve rc=$rc, expected 6"
  pass "surface outside current workspace is rejected"
}

test_collect_rejects_job_outside_current_workspace() {
  local fifo
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
├── workspace workspace:1 "current" [selected] ◀ active
│   └── pane pane:1 [focused] ◀ active
│       └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
└── workspace workspace:2 "other"
    └── pane pane:2 "reviewer"
        └── surface surface:9 [terminal] "claudee" [selected] tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  fifo="$(make_fifo "surface_9-outside")"
  set +e
  cmux_collect "surface_9-outside" --timeout 1 >/dev/null 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 6 ] || fail "outside job collect rc=$rc, expected 6"
  [ -p "$fifo" ] || fail "outside job collect removed FIFO"
  rm -f "$fifo"
  pass "collect refuses job outside current workspace"
}

test_cmux_watch_collects_without_manual_input() {
  local fifo ans out
  fifo="$(make_fifo "job-watch")"
  ans="${fifo%.res}.ans"
  (
    sleep 2
    printf 'watched' > "$ans.tmp"
    mv -f "$ans.tmp" "$ans"
  ) &

  out="$(cmux_watch "job-watch" --timeout 5 --interval 1 2>/dev/null)"
  wait 2>/dev/null || true

  [ "$out" = "watched" ] || fail "cmux_watch output was '$out'"
  [ ! -e "$fifo" ] || fail "cmux_watch left FIFO behind after success"
  pass "cmux_watch collects delayed result without manual collect"
}

test_cmux_send_returns_result_by_default() {
  local out
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
    └── pane pane:2 "reviewer"
        └── surface surface:9 [terminal] "claudee" [selected] tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0
  export CMUX_TEST_SEND_WRITE='auto-result'
  export CMUX_TEST_SEND_DELAY=1

  out="$(cmux_send "surface:9" "ping" --mode llm --timeout 5 --watch-interval 1 2>/dev/null)"

  unset CMUX_TEST_SEND_WRITE
  unset CMUX_TEST_SEND_DELAY
  [ "$out" = "auto-result" ] || fail "cmux_send default output was '$out'"
  pass "cmux_send returns result by default"
}

test_cmux_send_no_watch_returns_job_id() {
  local out
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
    └── pane pane:2 "reviewer"
        └── surface surface:9 [terminal] "claudee" [selected] tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  out="$(cmux_send "surface:9" "ping" --mode llm --no-watch 2>/dev/null)"
  case "$out" in
    surface_9-*) ;;
    *) fail "cmux_send --no-watch output was '$out'" ;;
  esac
  cmux_cancel "$out" >/dev/null 2>/dev/null || true
  pass "cmux_send --no-watch returns job id"
}

test_cmux_send_uses_long_send_defaults() {
  local args_file="$TMP_ROOT/send-watch-defaults.args"
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
    └── pane pane:2 "reviewer"
        └── surface surface:9 [terminal] "claudee" [selected] tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  (
    cmux_watch() {
      printf '%s\n' "$@" > "$args_file"
      return 0
    }
    cmux_send "surface:9" "ping" --mode llm >/dev/null 2>/dev/null
  )

  grep -q -- '--timeout' "$args_file" || fail "cmux_send did not pass --timeout to cmux_watch"
  grep -q '^3600$' "$args_file" || fail "cmux_send default timeout was not 3600"
  grep -q -- '--interval' "$args_file" || fail "cmux_send did not pass --interval to cmux_watch"
  grep -q '^15$' "$args_file" || fail "cmux_send default watch interval was not 15"
  rm -f "$CMUX_V5_FIFO_DIR"/surface_9-*.res
  pass "cmux_send uses long send-specific defaults"
}

test_short_aliases_delegate_hot_path() {
  local out fifo ans
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] ◀ active ◀ here tty=ttys001
    └── pane pane:2 "reviewer"
        └── surface surface:9 [terminal] "claudee" [selected] tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  export CMUX_TEST_SEND_WRITE='ask-alias'
  export CMUX_TEST_SEND_DELAY=0
  out="$(cmuxa "surface:9" "ping" --mode llm --timeout 3 2>/dev/null)"
  [ "$out" = "ask-alias" ] || fail "cmuxa output was '$out'"

  export CMUX_TEST_SEND_WRITE='send-alias'
  out="$(cmuxs "surface:9" "ping" --mode llm --timeout 3 --watch-interval 1 2>/dev/null)"
  [ "$out" = "send-alias" ] || fail "cmuxs output was '$out'"

  unset CMUX_TEST_SEND_WRITE
  unset CMUX_TEST_SEND_DELAY
  fifo="$(make_fifo "job-alias")"
  ans="${fifo%.res}.ans"
  (
    printf 'collect-alias' > "$ans.tmp"
    mv -f "$ans.tmp" "$ans"
  ) &
  out="$(cmuxg "job-alias" --timeout 3 2>/dev/null)"
  wait 2>/dev/null || true
  [ "$out" = "collect-alias" ] || fail "cmuxg output was '$out'"

  pass "short aliases cmuxa/cmuxs/cmuxg delegate"
}

test_cmux_cross_carries_objective_and_transcript() {
  local call_dir out
  call_dir="$TMP_ROOT/cross-calls"
  mkdir -p "$call_dir"
  printf '0' > "$call_dir/count"

  # shellcheck disable=SC2329
  _cmux_v5_resolve() {
    printf '%s' "$1"
  }

  # shellcheck disable=SC2329
  cmux_ask_unsafe() {
    local surface="$1" prompt="$2" n
    n="$(cat "$call_dir/count")"
    n=$((n + 1))
    printf '%s' "$n" > "$call_dir/count"
    printf '%s' "$surface" > "$call_dir/$n.surface"
    printf '%s' "$prompt" > "$call_dir/$n.prompt"
    printf '%s\n' "$@" > "$call_dir/$n.args"
    printf 'answer-%s' "$n"
  }

  out="$(cmuxc "target" "analyzer" "설계 목표를 고도화" --rounds 1 2>/dev/null)"

  [ "$out" = "answer-4" ] || fail "cmux_cross final output was '$out'"
  grep -q '설계 목표를 고도화' "$call_dir/2.prompt" || fail "feedback prompt missed original objective"
  grep -q 'Round 0 Target Initial Proposal' "$call_dir/2.prompt" || fail "feedback prompt missed transcript"
  grep -q 'answer-1' "$call_dir/2.prompt" || fail "feedback prompt missed target proposal"
  grep -q 'answer-2' "$call_dir/3.prompt" || fail "target response prompt missed feedback"
  grep -q '피드백별 수용/부분수용/기각' "$call_dir/3.prompt" || fail "target prompt does not require accept/reject reasoning"
  grep -q 'Round 1 Analyzer/Critic Feedback' "$call_dir/4.prompt" || fail "final prompt missed analyzer feedback transcript"
  grep -q 'Round 1 Target/Designer Response' "$call_dir/4.prompt" || fail "final prompt missed target response transcript"
  grep -q '라운드별 검토자 피드백' "$call_dir/4.prompt" || fail "final prompt does not require debate summary"
  pass "cmuxc delegates to cmux_cross and carries objective/transcript"
}

test_cmux_cross_two_arg_defaults() {
  local call_dir out count
  call_dir="$TMP_ROOT/cross-defaults"
  mkdir -p "$call_dir"
  printf '0' > "$call_dir/count"

  _cmux_v5_resolve() {
    printf '%s' "$1"
  }

  cmux_other_surfaces() {
    return 0
  }

  cmux_ask_unsafe() {
    local surface="$1" prompt="$2" n
    n="$(cat "$call_dir/count")"
    n=$((n + 1))
    printf '%s' "$n" > "$call_dir/count"
    printf '%s' "$surface" > "$call_dir/$n.surface"
    printf '%s' "$prompt" > "$call_dir/$n.prompt"
    printf '%s\n' "$@" > "$call_dir/$n.args"
    printf 'default-answer-%s' "$n"
  }

  out="$(cmux_cross "target-title" "목적을 같이 다듬어줘" 2>/dev/null)"
  count="$(cat "$call_dir/count")"

  [ "$out" = "default-answer-8" ] || fail "two-arg cmux_cross final output was '$out'"
  [ "$count" = "8" ] || fail "default rounds made $count calls, expected 8"
  grep -q '목적을 같이 다듬어줘' "$call_dir/1.prompt" || fail "two-arg cmux_cross did not treat second arg as prompt"
  grep -q 'Self-Refinement / Critic Round 3/3' "$call_dir/6.prompt" || fail "default rounds did not reach 3/3 critic prompt"
  grep -q -- '--timeout' "$call_dir/1.args" || fail "cmux_cross did not pass timeout option"
  grep -q '^1800$' "$call_dir/1.args" || fail "cmux_cross default timeout was not 1800"
  pass "cmux_cross two-arg form uses rounds=3 and timeout=1800 by default"
}

test_resolve_picks_lowest_on_duplicate_titles() {
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:5 [terminal] "codex" [selected] tty=ttys001
    └── pane pane:2
        └── surface surface:9 [terminal] "codex" [selected] ◀ here tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

  local resolved err
  set +e
  err="$(_cmux_v5_resolve "codex" 2>&1 >/dev/null)"
  resolved="$(_cmux_v5_resolve "codex" 2>/dev/null)"
  set -e

  [ "$resolved" = "surface:5" ] || fail "duplicate title resolved to '$resolved', want surface:5"
  echo "$err" | grep -q "matched 2 surfaces" || fail "no multi-match warning: $err"
  echo "$err" | grep -q "surface:9" || fail "warning should list surface:9: $err"
  pass "duplicate titles → lowest surface:N + stderr warning"
}

test_resolve_trace_off_emits_no_decision_log() {
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:1 [terminal] "codex" [selected] tty=ttys001
    └── pane pane:2
        └── surface surface:9 [terminal] "zsh" [selected] ◀ here tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0
  unset CMUX_V5_RESOLVE_TRACE

  local err
  set +e
  err="$(_cmux_v5_resolve "codex" 2>&1 >/dev/null)"
  set -e

  [ -z "$err" ] || fail "trace=off should not emit stderr on unique match: $err"
  pass "trace off keeps stderr clean on unique match"
}

test_resolve_trace_on_logs_match_key() {
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    ├── pane pane:1 "dev" [focused] ◀ active
    │   └── surface surface:9 [terminal] "" [selected] tty=ttys001
    └── pane pane:2
        └── surface surface:2 [terminal] "zsh" [selected] ◀ here tty=ttys002'
  _CMUX_V5_TREE_FOCUSED_CACHE=""
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME=0
  export CMUX_V5_RESOLVE_TRACE=on

  local err resolved
  set +e
  err="$(_cmux_v5_resolve "dev" 2>&1 >/dev/null)"
  resolved="$(_cmux_v5_resolve "dev" 2>/dev/null)"
  set -e
  unset CMUX_V5_RESOLVE_TRACE

  [ "$resolved" = "surface:9" ] || fail "pane_title match failed: $resolved"
  echo "$err" | grep -q "resolve trace" || fail "no trace log: $err"
  echo "$err" | grep -q "surface:9	p" || fail "trace should mark pane_title key: $err"
  pass "trace=on shows matching key on stderr"
}

test_job_registry_lock_serializes_attempts() {
  local i attempts
  reset_job_state

  _cmux_v5_job_new "lock-job" "surface:1" || fail "job registry did not create lock-job"

  i=0
  while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    (_cmux_v5_job_incr_attempts "lock-job" >/dev/null) &
  done
  wait

  attempts="$(_cmux_v5_job_get "lock-job" attempts)"
  [ "$attempts" = "12" ] || fail "concurrent attempts count was '$attempts', expected 12"
  pass "job registry lock serializes concurrent metadata updates"
}

test_lock_breaks_dead_pid_stale_lock() {
  local lockpath pid
  reset_job_state

  lockpath="$(_cmux_v5_lock_path "stale-job")"
  mkdir -p "$lockpath"
  printf '999999999' > "$lockpath/pid"
  date +%s > "$lockpath/ts"

  _cmux_v5_lock "stale-job" 1 || fail "lock did not break dead-pid stale lock"
  pid="$(cat "$lockpath/pid" 2>/dev/null)"
  [ "$pid" = "$$" ] || fail "stale lock pid was not replaced: '$pid'"
  _cmux_v5_unlock "stale-job"
  pass "lock breaks stale lock when owner pid is dead"
}

test_cmux_flow_happy_path_and_template_rendering() {
  local flow_file out log_dir
  reset_job_state
  log_dir="$TMP_ROOT/flow-happy-log"
  mkdir -p "$log_dir"
  FLOW_TEST_LOG_DIR="$log_dir"

  # shellcheck disable=SC2329
  _cmux_v5_flow_run_node() {
    local target="$1" prompt="$2" safe
    safe="$(printf '%s' "$target" | tr ':/ ' '___')"
    printf '%s' "$prompt" > "$FLOW_TEST_LOG_DIR/$safe.prompt"
    printf 'result:%s:%s' "$target" "$prompt"
  }

  flow_file="$TMP_ROOT/flow-happy.tsv"
  {
    printf 'a\tsurface:1\t-\talpha\n'
    printf 'b\tsurface:2\ta\tbeta {{a.result}}\n'
  } > "$flow_file"

  out="$(cmux_flow "$flow_file" 2>"$TMP_ROOT/flow-happy.err")" || fail "cmux_flow happy path failed"

  printf '%s\n' "$out" | grep -q "$(printf 'a\tDONE\t')" || fail "flow output missed DONE for a: $out"
  printf '%s\n' "$out" | grep -q "$(printf 'b\tDONE\t')" || fail "flow output missed DONE for b: $out"
  grep -q 'result:surface:1:alpha' "$log_dir/surface_2.prompt" || fail "flow did not render dependency result into b prompt"
  pass "cmux_flow runs DAG nodes and renders dependency result templates"
}

test_cmux_flow_failure_cascades_but_independent_branch_continues() {
  local flow_file out rc
  reset_job_state

  # shellcheck disable=SC2329
  _cmux_v5_flow_run_node() {
    local target="$1" prompt="$2"
    case "$prompt" in
      *fail*) return 9 ;;
    esac
    printf 'ok:%s:%s' "$target" "$prompt"
  }

  flow_file="$TMP_ROOT/flow-failure.tsv"
  {
    printf 'root\tsurface:1\t-\tfail root\n'
    printf 'child\tsurface:2\troot\tuses {{root.result}}\n'
    printf 'independent\tsurface:3\t-\tstill runs\n'
  } > "$flow_file"

  set +e
  out="$(cmux_flow "$flow_file" 2>"$TMP_ROOT/flow-failure.err")"
  rc=$?
  set -e

  [ "$rc" -eq 1 ] || fail "flow failure rc=$rc, expected 1"
  printf '%s\n' "$out" | grep -q "$(printf 'root\tFAILED\t')" || fail "root should be FAILED: $out"
  printf '%s\n' "$out" | grep -q "$(printf 'child\tCANCELLED\t')" || fail "child should be CANCELLED: $out"
  printf '%s\n' "$out" | grep -q "$(printf 'independent\tDONE\t')" || fail "independent branch should continue: $out"
  pass "cmux_flow cascades failed dependencies while independent branch continues"
}

test_cmux_flow_rejects_unknown_deps_and_cycles() {
  local flow_file rc err
  reset_job_state

  flow_file="$TMP_ROOT/flow-unknown.tsv"
  printf 'a\tsurface:1\tmissing\twill not run\n' > "$flow_file"
  set +e
  cmux_flow "$flow_file" >/dev/null 2>"$TMP_ROOT/flow-unknown.err"
  rc=$?
  set -e
  err="$(cat "$TMP_ROOT/flow-unknown.err")"
  [ "$rc" -eq 2 ] || fail "unknown dep rc=$rc, expected 2"
  printf '%s\n' "$err" | grep -q 'unknown dep "missing"' || fail "unknown dep error was not explicit: $err"

  reset_job_state
  flow_file="$TMP_ROOT/flow-cycle.tsv"
  {
    printf 'a\tsurface:1\tb\tcycle a\n'
    printf 'b\tsurface:2\ta\tcycle b\n'
  } > "$flow_file"
  set +e
  cmux_flow "$flow_file" >/dev/null 2>"$TMP_ROOT/flow-cycle.err"
  rc=$?
  set -e
  err="$(cat "$TMP_ROOT/flow-cycle.err")"
  [ "$rc" -eq 2 ] || fail "cycle rc=$rc, expected 2"
  printf '%s\n' "$err" | grep -q 'cycle detected' || fail "cycle error was not explicit: $err"
  pass "cmux_flow rejects unknown dependencies and cycles"
}

test_cmux_flow_cap_routing_spreads_ready_wave() {
  local flow_file out targets unique_count
  reset_job_state
  FLOW_TEST_LOG_DIR="$TMP_ROOT/flow-route-log"
  mkdir -p "$FLOW_TEST_LOG_DIR"

  # shellcheck disable=SC2329
  _cmux_v5_resolve() {
    printf '%s' "$1"
  }

  # shellcheck disable=SC2329
  cmux_other_surfaces() {
    printf 'surface:1\nsurface:2\n'
  }

  # shellcheck disable=SC2329
  _cmux_v5_surface_title() {
    case "$1" in
      surface:1) printf 'codex-a' ;;
      surface:2) printf 'codex-b' ;;
    esac
  }

  # shellcheck disable=SC2329
  _cmux_v5_detect() {
    printf 'llm'
  }

  # shellcheck disable=SC2329
  _cmux_v5_flow_run_node() {
    printf '%s\n' "$1" >> "$FLOW_TEST_LOG_DIR/targets"
    sleep 1
    printf 'routed:%s' "$1"
  }

  flow_file="$TMP_ROOT/flow-route.tsv"
  {
    printf 'r1\t@codex\t-\troute one\n'
    printf 'r2\t@codex\t-\troute two\n'
  } > "$flow_file"

  out="$(cmux_flow "$flow_file" 2>"$TMP_ROOT/flow-route.err")" || fail "routed cmux_flow failed: $out"
  targets="$(cat "$FLOW_TEST_LOG_DIR/targets" 2>/dev/null)"
  unique_count="$(printf '%s\n' "$targets" | sort -u | wc -l | tr -d ' ')"
  [ "$unique_count" = "2" ] || fail "route lock did not spread wave across surfaces: $targets"
  printf '%s\n' "$targets" | grep -q '^surface:1$' || fail "route did not use surface:1: $targets"
  printf '%s\n' "$targets" | grep -q '^surface:2$' || fail "route did not use surface:2: $targets"
  pass "cmux_flow @cap routing spreads concurrent ready nodes"
}

test_trace_and_metrics_report_job_registry_state() {
  local trace metrics
  reset_job_state

  # shellcheck disable=SC2329
  _cmux_v5_resolve() {
    printf '%s' "$1"
  }

  _cmux_v5_job_new "obs-flow__a" "surface:1" || fail "could not create obs a"
  _cmux_v5_job_set_state "obs-flow__a" DISPATCHING
  _cmux_v5_job_set_result "obs-flow__a" "done-a"
  _cmux_v5_job_set_state "obs-flow__a" DONE

  _cmux_v5_job_new "obs-flow__b" "surface:1" || fail "could not create obs b"
  _cmux_v5_job_set_state "obs-flow__b" DISPATCHING
  _cmux_v5_job_set_state "obs-flow__b" FAILED

  _cmux_v5_job_new "obs-flow__c" "surface:2" || fail "could not create obs c"
  _cmux_v5_job_set_state "obs-flow__c" CANCELLED

  trace="$(cmux_trace "obs-flow" 2>"$TMP_ROOT/trace.err")" || fail "cmux_trace failed"
  printf '%s\n' "$trace" | grep -q '^NODE' || fail "trace missed table header: $trace"
  printf '%s\n' "$trace" | grep -q '^a[[:space:]]*DONE' || fail "trace missed DONE node a: $trace"
  printf '%s\n' "$trace" | grep -q '^b[[:space:]]*FAILED' || fail "trace missed FAILED node b: $trace"
  printf '%s\n' "$trace" | grep -q '^GANTT' || fail "trace missed gantt output: $trace"

  metrics="$(cmux_metrics 2>"$TMP_ROOT/metrics.err")" || fail "cmux_metrics failed"
  printf '%s\n' "$metrics" | awk '$1=="surface:1" && $2=="2" && $3=="1" && $4=="1" && $5=="0" && $6=="50" { ok=1 } END { exit ok ? 0 : 1 }' \
    || fail "metrics did not aggregate surface:1 correctly: $metrics"
  printf '%s\n' "$metrics" | awk '$1=="surface:2" && $2=="1" && $3=="0" && $4=="0" && $5=="1" && $6=="-" { ok=1 } END { exit ok ? 0 : 1 }' \
    || fail "metrics did not aggregate surface:2 cancellation correctly: $metrics"
  pass "cmux_trace and cmux_metrics report job registry state"
}

test_collect_empty_answer_returns_immediately() {
  local fifo ans rc out start elapsed
  fifo="$(make_fifo "job-empty-ans")"
  ans="${fifo%.res}.ans"
  # side-effect-only worker 답변: 0바이트 .ans 가 atomic 하게 나타난 상태.
  : > "$ans"

  start="$(date +%s)"
  set +e
  out="$(cmux_collect "job-empty-ans" --timeout 10 2>/dev/null)"
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - start ))

  [ "$rc" -eq 0 ] || fail "empty answer collect rc=$rc, expected 0"
  [ -z "$out" ] || fail "empty answer collect output was '$out'"
  [ "$elapsed" -lt 5 ] || fail "empty answer collect took ${elapsed}s — hang until timeout"
  [ ! -e "$fifo" ] || fail "empty answer collect left FIFO behind"
  [ ! -e "$ans" ] || fail "empty answer collect left .ans behind"
  pass "empty .ans answer returns immediately instead of hanging"
}

test_detect_falls_back_to_title_hint() {
  local mode
  # tty 가 tree 에 없으면 ps 기반 감지가 불가 → title 키워드 폴백으로 llm.
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    └── pane pane:1 [focused] ◀ active
        └── surface surface:9 [terminal] "codex-main" [selected] ◀ here'
  _CMUX_V5_TREE_CACHE=""
  _CMUX_V5_TREE_CACHE_TIME=0

  mode="$(_cmux_v5_detect "surface:9")" || true
  [ "$mode" = "llm" ] || fail "title hint detect returned '$mode', want llm"

  # LLM 키워드가 없는 title 은 여전히 unknown.
  export CMUX_TEST_TREE='window window:1 [current] ◀ active
└── workspace workspace:1 "test" [selected] ◀ active
    └── pane pane:1 [focused] ◀ active
        └── surface surface:9 [terminal] "build-log" [selected] ◀ here'
  _CMUX_V5_TREE_CACHE=""
  _CMUX_V5_TREE_CACHE_TIME=0

  mode="$(_cmux_v5_detect "surface:9")" || true
  [ "$mode" = "unknown" ] || fail "non-llm title detect returned '$mode', want unknown"
  pass "mode detect falls back to surface title hint"
}

test_collect_timeout_preserves_fifo
test_collect_success_unlinks_fifo
test_collect_empty_answer_returns_immediately
test_detect_falls_back_to_title_hint
test_truncation_metadata_is_out_of_band
test_truncation_keeps_utf8_boundary
test_worker_focus_guard_blocks_active_surface
test_cmux_send_worker_guard_blocks_before_fifo
test_worker_focus_guard_allows_inactive_surface
test_resolve_accepts_pane_name_in_current_workspace
test_resolve_prefers_surface_title_over_pane_title
test_resolve_duplicate_surface_titles_warn_and_pick_lowest
test_surface_title_matches_exact_surface_id
test_resolve_rejects_surface_outside_current_workspace
test_collect_rejects_job_outside_current_workspace
test_cmux_watch_collects_without_manual_input
test_cmux_send_returns_result_by_default
test_cmux_send_no_watch_returns_job_id
test_cmux_send_uses_long_send_defaults
test_short_aliases_delegate_hot_path
test_resolve_picks_lowest_on_duplicate_titles
test_resolve_trace_off_emits_no_decision_log
test_resolve_trace_on_logs_match_key
test_cmux_cross_carries_objective_and_transcript
test_cmux_cross_two_arg_defaults
test_job_registry_lock_serializes_attempts
test_lock_breaks_dead_pid_stale_lock
test_cmux_flow_happy_path_and_template_rendering
test_cmux_flow_failure_cascades_but_independent_branch_continues
test_cmux_flow_rejects_unknown_deps_and_cycles
test_cmux_flow_cap_routing_spreads_ready_wave
test_trace_and_metrics_report_job_registry_state
