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

  out="$(cmux_cross "target" "analyzer" "설계 목표를 고도화" --rounds 1 2>/dev/null)"

  [ "$out" = "answer-4" ] || fail "cmux_cross final output was '$out'"
  grep -q '설계 목표를 고도화' "$call_dir/2.prompt" || fail "feedback prompt missed original objective"
  grep -q 'Round 0 Target Initial Proposal' "$call_dir/2.prompt" || fail "feedback prompt missed transcript"
  grep -q 'answer-1' "$call_dir/2.prompt" || fail "feedback prompt missed target proposal"
  grep -q 'answer-2' "$call_dir/3.prompt" || fail "target response prompt missed feedback"
  grep -q '피드백별 수용/부분수용/기각' "$call_dir/3.prompt" || fail "target prompt does not require accept/reject reasoning"
  grep -q 'Round 1 Analyzer/Critic Feedback' "$call_dir/4.prompt" || fail "final prompt missed analyzer feedback transcript"
  grep -q 'Round 1 Target/Designer Response' "$call_dir/4.prompt" || fail "final prompt missed target response transcript"
  grep -q '라운드별 검토자 피드백' "$call_dir/4.prompt" || fail "final prompt does not require debate summary"
  pass "cmux_cross carries objective and transcript through debate"
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

test_collect_timeout_preserves_fifo
test_collect_success_unlinks_fifo
test_truncation_metadata_is_out_of_band
test_truncation_keeps_utf8_boundary
test_worker_focus_guard_blocks_active_surface
test_cmux_send_worker_guard_blocks_before_fifo
test_worker_focus_guard_allows_inactive_surface
test_resolve_accepts_pane_name_in_current_workspace
test_resolve_rejects_surface_outside_current_workspace
test_collect_rejects_job_outside_current_workspace
test_cmux_watch_collects_without_manual_input
test_cmux_send_returns_result_by_default
test_cmux_send_no_watch_returns_job_id
test_cmux_cross_carries_objective_and_transcript
test_cmux_cross_two_arg_defaults
