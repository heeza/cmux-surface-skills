#!/usr/bin/env bash
# cmux v5 — FIFO 응답 채널 + cap-discipline + auto-detect (LLM | worker)
#
# 변경점 (vs v3/v4):
#  - 응답은 per-job FIFO blocking read. read-screen fallback 은 opt-in.
#  - sidecar 정체 자동 감지 (claude/codex/gemini/pi/.. = llm, zsh/bash/.. = worker).
#  - 4종 cap 강제 (prompt size / response size / timeout / auto-cap 문구).
#  - cmux_ask 는 기본 안전, cmux_ask_unsafe 는 명시적 escape valve.
#
# Public:  cmux_ask  cmux_ask_unsafe  cmux_send  cmux_collect
#          cmux_check  cmux_tail  cmux_cancel
#          cmux_by_title (alias)  cmux_other_surfaces
#
# v5.1 — cmux_ask / cmux_ask_unsafe / cmux_send / cmux_cancel 의 surface 인자는
#        "surface:N" 또는 surface 의 title 둘 다 받음. title 사용 시 첫 매치.
#
# 사용:
#   source /path/to/cmux-v5-lib.sh
#   ANSWER=$(cmux_ask surface:9 "현재 브랜치만 알려줘")
#   ANSWER=$(cmux_ask "codex" "git log -5 --oneline" --mode worker)
#   job=$(cmux_send "codex" "build 끝나면 한 줄 요약")
#   RESULT=$(cmux_collect "$job" --timeout 600)

# ---- defaults (env override 가능) ----
: "${CMUX_V5_PROMPT_MAX:=500}"      # prompt 글자 cap
: "${CMUX_V5_RESPONSE_MAX:=4096}"   # 응답 바이트 cap
: "${CMUX_V5_TIMEOUT:=1200}"        # blocking read 초
: "${CMUX_V5_AUTO_CAP:=on}"         # on|off — prompt 끝에 안내문 자동 첨부
: "${CMUX_V5_FIFO_DIR:=/tmp/cmux-fifo}"
: "${CMUX_V5_FALLBACK_SCREEN:=off}" # on|off — FIFO 무응답 시 read-screen 마커 추출 fallback
: "${CMUX_V5_SCREEN_LINES:=200}"    # fallback 추출 시 read-screen 라인 수
: "${CMUX_V5_PROMPT_STYLE:=compact}" # compact|verbose — LLM 수신 규칙 길이
: "${CMUX_V5_EARLY_IDLE:=off}"      # off|worker|llm|on — 실패 조기 감지용 polling
: "${CMUX_V5_POLL_INTERVAL:=1}"     # early-idle polling 간격

# ---- private ----

_CMUX_V5_TREE_CACHE=""
_CMUX_V5_TREE_CACHE_TIME=0
_CMUX_V5_TREE_FOCUSED_CACHE=""
_CMUX_V5_TREE_FOCUSED_CACHE_TIME=0

_cmux_v5_get_tree() {
  local now
  now=$(date +%s)
  if [ -n "$_CMUX_V5_TREE_CACHE" ] && [ $((now - _CMUX_V5_TREE_CACHE_TIME)) -lt 1 ]; then
    printf '%s\n' "$_CMUX_V5_TREE_CACHE"
    return 0
  fi
  _CMUX_V5_TREE_CACHE="$(cmux tree --all 2>/dev/null)"
  _CMUX_V5_TREE_CACHE_TIME="$now"
  printf '%s\n' "$_CMUX_V5_TREE_CACHE"
}

_cmux_v5_get_tree_focused() {
  local now
  now=$(date +%s)
  if [ -n "$_CMUX_V5_TREE_FOCUSED_CACHE" ] && [ $((now - _CMUX_V5_TREE_FOCUSED_CACHE_TIME)) -lt 1 ]; then
    printf '%s\n' "$_CMUX_V5_TREE_FOCUSED_CACHE"
    return 0
  fi
  _CMUX_V5_TREE_FOCUSED_CACHE="$(cmux tree 2>/dev/null)"
  _CMUX_V5_TREE_FOCUSED_CACHE_TIME="$now"
  printf '%s\n' "$_CMUX_V5_TREE_FOCUSED_CACHE"
}

# title-or-ref → surface:N. 인자가 surface:N 패턴이면 그대로, 아니면 title lookup.
# 다중 매치 시 첫 번째. 실패 시 stderr + rc 6.
_cmux_v5_resolve() {
  local arg="$1"
  if [[ "$arg" =~ ^surface:[0-9]+$ ]]; then
    printf '%s' "$arg"
    return 0
  fi
  local ref
  ref="$(_cmux_v5_get_tree \
    | grep -F "\"$arg\"" \
    | grep -oE 'surface:[0-9]+' \
    | head -1)"
  if [ -z "$ref" ]; then
    printf '[cmux v5] cannot resolve "%s" — not surface:N nor a matched title\n' "$arg" >&2
    return 6
  fi
  printf '%s' "$ref"
}

_cmux_v5_job() {
  local surface="$1"
  local prefix=""
  if [ -n "$surface" ]; then
    prefix="${surface//:/_}-"
  fi
  printf '%s%s-%s-%s' \
    "$prefix" \
    "$(date +%s%N)" \
    "$$" \
    "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

_cmux_v5_fifo_path() {
  printf '%s/%s.res' "$CMUX_V5_FIFO_DIR" "$1"
}

_cmux_v5_garbage_collect() {
  # 12시간(720분) 이상 방치된 FIFO 파일들을 백그라운드에서 조용히 정리
  find "$CMUX_V5_FIFO_DIR" -type p -mmin +720 -delete 2>/dev/null &
}

_cmux_v5_init_dir() {
  [ -d "$CMUX_V5_FIFO_DIR" ] && { _cmux_v5_garbage_collect; return 0; }
  mkdir -p "$CMUX_V5_FIFO_DIR" && chmod 700 "$CMUX_V5_FIFO_DIR"
  _cmux_v5_garbage_collect
}

_cmux_v5_make_fifo() {
  local job="$1" fifo
  fifo="$(_cmux_v5_fifo_path "$job")"
  _cmux_v5_init_dir || return 1
  rm -f "$fifo"
  mkfifo -m 0600 "$fifo" || return 1
  printf '%s' "$fifo"
}

# FIFO filename (full path or basename) → surface ref ("surface:N") or 빈 문자열.
# bash/zsh 양쪽 호환을 위해 capture 대신 parameter expansion 사용.
_cmux_v5_fifo_to_surface() {
  local arg="$1"
  local base="${arg##*/}"
  base="${base%.res}"
  case "$base" in
    surface_*) ;;
    *) return 0 ;;
  esac
  local num="${base#surface_}"
  num="${num%%-*}"
  case "$num" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf 'surface:%s' "$num"
}

# surface ref 가 현재 cmux tree 에 존재하는지. rc 0 = alive, 1 = gone.
_cmux_v5_surface_alive() {
  local surface="$1"
  [ -z "$surface" ] && return 1
  local num="${surface#surface:}"
  _cmux_v5_get_tree | grep -qE "surface:${num}([^0-9]|$)"
}

# surface ref 의 가장 최근 (mtime) pending FIFO 한 개 path. 없으면 빈 문자열.
_cmux_v5_pick_fifo() {
  local surface="$1"
  [ -z "$surface" ] && return 1
  local prefix="${surface/:/_}"
  local f
  for f in $(ls -t "$CMUX_V5_FIFO_DIR/${prefix}-"*.res 2>/dev/null); do
    if [ -p "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# surface ref → title ("" 없으면). cmux tree 에서 "...." 안의 첫 토큰 매칭.
_cmux_v5_surface_title() {
  local surface="$1"
  [ -z "$surface" ] && return 1
  _cmux_v5_get_tree \
    | awk -v s="$surface" '
        index($0, s) > 0 {
          if (match($0, /"[^"]+"/)) {
            print substr($0, RSTART+1, RLENGTH-2); exit
          }
        }'
}

# echo: llm | worker | unknown
_cmux_v5_detect() {
  local surface="$1" tty short leader args

  # surface ref → tty. surface UUID 도 cmux tree 가 표시하므로 substring match
  tty="$(_cmux_v5_get_tree \
    | awk -v s="$surface" '
        $0 ~ s {
          if (match($0, /tty=[^ ]+/)) {
            print substr($0, RSTART+4, RLENGTH-4); exit
          }
        }')"
  if [ -z "$tty" ]; then
    echo unknown
    return 1
  fi

  short="${tty##/dev/}"
  # PTY 에 여러 child 가 동시에 attach 됨 (LLM TUI + MCP servers + npm + node).
  # 단일 leader 추출은 fragile — full process list 에 대한 whitelist 매칭으로 결정.
  local procs
  procs="$(ps -ww -t "$short" -o args= 2>/dev/null)"
  if [ -z "$procs" ]; then
    echo unknown
    return 1
  fi

  # LLM 우선 매칭 (LLM 이 떠 있으면 shell 도 같이 있는 게 정상)
  if printf '%s' "$procs" \
      | grep -qE '(^|/)(claude|codex|gemini|opencode|omc|omo|omx|agy|antigravity|junie)( |$)'; then
    echo llm; return 0
  fi
  if printf '%s' "$procs" | grep -qiE '(anthropic|openai|antigravity)'; then
    echo llm; return 0
  fi
  # claude/codex 의 node-launched 변형
  if printf '%s' "$procs" | grep -qE 'node .*(claude|codex|gemini|agy|antigravity)'; then
    echo llm; return 0
  fi
  # 사용자 정의 — pi 같이 짧은 이름
  if printf '%s' "$procs" | grep -qE '(^|/)pi( |$)'; then
    echo llm; return 0
  fi

  # LLM 흔적 없음 → shell 이면 worker
  if printf '%s' "$procs" | grep -qE '(^|/| )(zsh|bash|fish|dash|ksh|tcsh)( |$)'; then
    echo worker; return 0
  fi
  # 일반 sh 매칭 (위 grep 가 -sh 도 잡으니 별도)
  if printf '%s' "$procs" | grep -qE '(^|/)sh( |$)'; then
    echo worker; return 0
  fi

  echo unknown
  return 1
}

# job_id tail 8 자 → screen fallback 마커 토큰. sync/async 양쪽에서 동일하게 재계산 가능.
_cmux_v5_screen_token() {
  local job="$1"
  local t="${job##*-}"
  printf '%s' "${t:0:8}"
}

# screen 에서 === CMUX_<token>_BEGIN === ... === CMUX_<token>_END === 사이 본문 추출.
# 빈 문자열이면 미발견. 다중 매치 시 마지막 블록 (최신).
_cmux_v5_screen_extract() {
  local surface="$1" token="$2" lines="${3:-$CMUX_V5_SCREEN_LINES}"
  [ -z "$surface" ] || [ -z "$token" ] && return 1
  local screen
  screen="$(cmux read-screen --surface "$surface" --lines "$lines" 2>/dev/null)" || return 1
  printf '%s\n' "$screen" | awk -v t="$token" '
    BEGIN { in_block=0; out=""; last="" }
    {
      if (index($0, "=== CMUX_" t "_BEGIN ===") > 0) { in_block=1; out=""; next }
      if (index($0, "=== CMUX_" t "_END ===") > 0) {
        if (in_block) { last = out; out = "" }
        in_block = 0; next
      }
      if (in_block) { out = (out=="" ? $0 : out "\n" $0) }
    }
    END {
      if (last != "") printf "%s", last
      else if (out != "" && in_block == 0) printf "%s", out
      else if (out != "" && in_block == 1) printf "%s", out
    }
  '
}

_cmux_v5_llm_prompt() {
  local body="$1" fifo="$2" job="$3" delim token
  if [ "$CMUX_V5_AUTO_CAP" = "on" ]; then
    delim="CMUX_END_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    token="$(_cmux_v5_screen_token "$job")"
    if [ "${CMUX_V5_PROMPT_STYLE:-compact}" = "verbose" ]; then
      if [ "$CMUX_V5_FALLBACK_SCREEN" = "on" ] && [ -n "$token" ]; then
        cat <<EOF
$body

[규칙 — 우선순위 순]
1. Bash 호출 가능하면 마지막 Bash 도구 호출로 본문을 FIFO 에 heredoc 으로 쓸 것 (chat 출력 X):
    cat > $fifo <<'$delim'
    답변 본문
    $delim
2. Bash 호출 불가하면 답변을 chat 에 출력하되 첫 줄과 마지막 줄은 아래 마커를 정확히 그대로:
   === CMUX_${token}_BEGIN ===
   답변 본문
   === CMUX_${token}_END ===
- 답변은 간결하게.
EOF
      else
        cat <<EOF
$body

[cmux]
마지막 Bash 도구 호출로 답변 본문만 FIFO 에 작성. chat 출력 금지.
cat > $fifo <<'$delim'
<답변 본문>
$delim
답변은 간결하게.
EOF
      fi
    elif [ "$CMUX_V5_FALLBACK_SCREEN" = "on" ] && [ -n "$token" ]; then
      cat <<EOF
$body

[cmux] 답변은 짧게. 가능하면 Bash 도구 마지막 호출로 FIFO 에만 작성:
cat > $fifo <<'$delim'
<answer>
$delim
Bash 불가하면 chat 에 아래 마커만 사용:
=== CMUX_${token}_BEGIN ===
<answer>
=== CMUX_${token}_END ===
EOF
    else
      cat <<EOF
$body

[cmux] 답변은 짧게. 마지막 Bash 도구 호출로 FIFO 에만 작성. chat 출력 금지:
cat > $fifo <<'$delim'
<answer>
$delim
EOF
    fi
  else
    printf '%s\n' "$body"
  fi
}

_cmux_v5_worker_prompt() {
  local body="$1" fifo="$2"
  if [ "$CMUX_V5_AUTO_CAP" = "on" ]; then
    # body 가 단일 shell command. 그대로 redirect.
    printf '{ %s ; } > %s 2>&1\n' "$body" "$fifo"
  else
    printf '%s\n' "$body"
  fi
}

_cmux_v5_send() {
  local surface="$1" full="$2"
  # send 와 send-key 가 별개 RPC. 데몬 처리 race 로 Enter 가 본문보다 먼저
  # 도착 / 휘발할 수 있어 짧은 stall + 재시도 패턴.
  cmux send --surface "$surface" -- "$full" >/dev/null 2>&1 || return 1
  sleep "${CMUX_V5_ENTER_DELAY:-0.15}"
  cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || return 1
  # Enter 휘발 보험. 빈 라인 한 번 더 — sidecar 입력창에 무해.
  if [ "${CMUX_V5_ENTER_DOUBLE:-on}" = "on" ]; then
    sleep 0.05
    cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || true
  fi
}

# blocking read with hard timeout (perl alarm) + byte cap.
# stdout: 본문, stderr: 경고, exit: 0=ok, 124=timeout, 5=open fail
_cmux_v5_read_fifo() {
  local fifo="$1" timeout="$2" max="$3"
  perl - "$timeout" "$fifo" "$max" <<'PERL'
my ($timeout, $fifo, $max) = @ARGV;
$SIG{ALRM} = sub {
  print STDERR "[cmux v5] timeout after ${timeout}s\n";
  exit 124;
};
alarm $timeout;
open(my $fh, "<", $fifo) or do {
  print STDERR "[cmux v5] open fail: $!\n";
  exit 5;
};
my $buf = "";
my $remaining = $max + 0;
while ($remaining > 0) {
  my $chunk;
  my $r = sysread $fh, $chunk, $remaining;
  if (!defined $r) {
    print STDERR "[cmux v5] read err: $!\n";
    last;
  }
  last if $r == 0;
  $buf .= $chunk;
  $remaining -= $r;
}
alarm 0;
close $fh;
print $buf;
exit 0;
PERL
}

# dynamic read with sidecar status check and fallback
_cmux_v5_read_fifo_dynamic() {
  local fifo="$1" surface="$2" mode="$3" timeout="$4" rmax="$5"

  if [ -n "$surface" ] && [ -z "$mode" ]; then
    mode="$(_cmux_v5_detect "$surface")"
  fi

  local early_idle=0
  case "${CMUX_V5_EARLY_IDLE:-off}" in
    on) early_idle=1 ;;
    worker) [ "$mode" = "worker" ] && early_idle=1 ;;
    llm) [ "$mode" = "llm" ] && early_idle=1 ;;
    off|"") early_idle=0 ;;
    *) early_idle=0 ;;
  esac

  local poll_interval="${CMUX_V5_POLL_INTERVAL:-1}"
  local max_idle_checks="${CMUX_V5_MAX_IDLE_CHECKS:-10}"

  # TTY 한번만 조회
  local tty="" short=""
  if [ -n "$surface" ]; then
    tty="$(_cmux_v5_get_tree \
      | awk -v s="$surface" '
          $0 ~ s {
            if (match($0, /tty=[^ ]+/)) {
              print substr($0, RSTART+4, RLENGTH-4); exit
            }
          }')"
    if [ -n "$tty" ]; then
      short="${tty##/dev/}"
    fi
  fi

  local out
  # 단 한 번의 perl 호출로 FIFO 읽기 및 early idle 감지 루프 전체를 위임
  out="$(perl - "$fifo" "$surface" "$mode" "$timeout" "$rmax" "$early_idle" "$poll_interval" "$max_idle_checks" "$short" <<'PERL'
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NONBLOCK);
use Time::HiRes qw(time sleep);
use IO::Select;

my ($fifo, $surface, $mode, $timeout, $rmax, $early_idle, $poll_interval, $max_idle_checks, $short) = @ARGV;
$timeout = $timeout + 0;
$rmax = $rmax + 0;
$early_idle = $early_idle + 0;
$poll_interval = $poll_interval + 0;
$max_idle_checks = $max_idle_checks + 0;

my $start_time = time;
my $deadline = $start_time + $timeout;
my $buf = "";
my $remaining = $rmax;

sysopen(my $fh, $fifo, O_RDONLY | O_NONBLOCK) or do {
    print STDERR "[cmux v5] open fail: $!\n";
    exit 5;
};
my $select = IO::Select->new($fh);

my $idle_count = 0;
my $last_screen_hash = "";

my $rc = 124;
while (time < $deadline && $remaining > 0) {
    if ($select->can_read($poll_interval)) {
        my $chunk;
        my $r = sysread $fh, $chunk, $remaining;
        if (!defined $r) {
            print STDERR "[cmux v5] read err: $!\n";
            $rc = 5;
            last;
        }
        if ($r == 0) {
            # EOF
            $rc = 0;
            last;
        }
        $buf .= $chunk;
        $remaining -= $r;
        $rc = 0;
        next;
    }
    
    if (time >= $deadline) {
        $rc = 124;
        last;
    }
    
    # Early idle detection
    if ($early_idle && $short && $mode ne "unknown") {
        my $is_active = 1;
        my $procs = `ps -ww -t "$short" -o args= 2>/dev/null` // "";
        
        if ($mode eq "worker") {
            my @active = grep { $_ !~ m{(^|/)(zsh|bash|sh|fish|dash|ksh|tcsh)( |$)} && $_ !~ /ps -ww/ } split(/\n/, $procs);
            if (@active == 0) {
                $is_active = 0;
            }
        } elsif ($mode eq "llm") {
            my $screen = `cmux read-screen --surface "$surface" --lines 30 2>/dev/null` // "";
            my $hash_val = length($screen) . "_" . ($screen =~ tr/\n/\n/);
            
            if ($hash_val eq $last_screen_hash) {
                $idle_count++;
                if ($screen =~ /(User:|Input:|Prompt:|❯|>\s*$)/i || $screen =~ /(User:|Input:|Prompt:|❯|>\s*)$/) {
                    $is_active = 0;
                } elsif ($idle_count >= $max_idle_checks) {
                    $is_active = 0;
                }
            } else {
                $last_screen_hash = $hash_val;
                $idle_count = 0;
            }
        }
        
        if (!$is_active) {
            print STDERR "[cmux v5] sidecar on $surface became idle without writing to FIFO. terminating wait.\n";
            $rc = 125;
            last;
        }
    }
}
close $fh;
print $buf;
exit $rc;
PERL
)"
  local rc=$?
  printf '%s' "$out"
  return $rc
}

# 공통 dispatcher (cap 검사 이후 호출됨)
_cmux_v5_dispatch() {
  local surface="$1" prompt="$2" mode="$3" timeout="$4" rmax="$5"

  if [ -z "$mode" ]; then
    mode="$(_cmux_v5_detect "$surface")"
  fi
  if [ "$mode" = "unknown" ]; then
    printf '[cmux v5] cannot auto-detect sidecar on %s. use --mode llm|worker.\n' \
      "$surface" >&2
    return 3
  fi
  if [ "$mode" != "llm" ] && [ "$mode" != "worker" ]; then
    printf '[cmux v5] bad mode: %s\n' "$mode" >&2
    return 2
  fi

  local job fifo
  job="$(_cmux_v5_job "$surface")"
  fifo="$(_cmux_v5_make_fifo "$job")" || {
    printf '[cmux v5] mkfifo failed\n' >&2; return 4
  }

  local full
  case "$mode" in
    llm)    full="$(_cmux_v5_llm_prompt    "$prompt" "$fifo" "$job")" ;;
    worker) full="$(_cmux_v5_worker_prompt "$prompt" "$fifo")" ;;
  esac

  if ! _cmux_v5_send "$surface" "$full"; then
    printf '[cmux v5] cmux send failed (surface=%s)\n' "$surface" >&2
    rm -f "$fifo"
    return 5
  fi

  local out rc start elapsed mark
  start=$(date +%s)
  out="$(_cmux_v5_read_fifo_dynamic "$fifo" "$surface" "$mode" "$timeout" "$rmax")"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  rm -f "$fifo"

  # Fallback: LLM 모드 + FIFO 무응답이면 screen 마커 추출 시도.
  local used_screen=0
  if [ "${CMUX_V5_FALLBACK_SCREEN:-off}" = "on" ] \
     && [ "$mode" = "llm" ] \
     && { [ "$rc" -ne 0 ] || [ "${#out}" -eq 0 ]; }; then
    local token screen_out
    token="$(_cmux_v5_screen_token "$job")"
    screen_out="$(_cmux_v5_screen_extract "$surface" "$token")"
    if [ -n "$screen_out" ]; then
      if [ "${#screen_out}" -gt "$rmax" ]; then
        out="${screen_out:0:$rmax}"
      else
        out="$screen_out"
      fi
      rc=0
      used_screen=1
    fi
  fi

  # stderr 한 줄 status (default on, CMUX_V5_QUIET=on 으로 끔)
  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    case "$rc" in
      0)   mark="ok" ;;
      124) mark="timeout" ;;
      125) mark="early_idle" ;;
      *)   mark="rc=$rc" ;;
    esac
    [ "$used_screen" -eq 1 ] && mark="$mark,screen-fallback"
    if [ "$rc" -eq 0 ] && [ "${#out}" -ge "$rmax" ]; then
      mark="$mark,truncated"
    fi
    printf '[cmux v5] %s (%s) %ds %dB %s\n' \
      "$surface" "$mode" "$elapsed" "${#out}" "$mark" >&2
  fi

  printf '%s' "$out"
  return $rc
}

# ---- public ----

# cmux_ask <surface> <prompt> [--mode llm|worker] [--timeout N]
cmux_ask() {
  if [ $# -lt 2 ]; then
    printf 'usage: cmux_ask <surface> <prompt> [--mode llm|worker] [--timeout N]\n' >&2
    return 2
  fi
  local surface="$1" prompt="$2" mode="" timeout="$CMUX_V5_TIMEOUT"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)    mode="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      *) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ "${#prompt}" -gt "$CMUX_V5_PROMPT_MAX" ]; then
    printf '[cmux v5] prompt size %d > PROMPT_MAX=%d. use cmux_ask_unsafe if intentional.\n' \
      "${#prompt}" "$CMUX_V5_PROMPT_MAX" >&2
    return 2
  fi
  surface="$(_cmux_v5_resolve "$surface")" || return 6
  _cmux_v5_dispatch "$surface" "$prompt" "$mode" "$timeout" "$CMUX_V5_RESPONSE_MAX"
}

# cmux_ask_unsafe — cap 우회. 큰 응답이 의도적임을 호출자가 선언.
# cmux_ask_unsafe <surface> <prompt> [--mode ...] [--timeout N]
#                [--prompt-max N] [--response-max N]
cmux_ask_unsafe() {
  if [ $# -lt 2 ]; then
    printf 'usage: cmux_ask_unsafe <surface> <prompt> [opts]\n' >&2
    return 2
  fi
  local surface="$1" prompt="$2" mode="" \
    timeout="$CMUX_V5_TIMEOUT" prompt_max=99999 response_max=$((1024*1024))
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)         mode="$2"; shift 2 ;;
      --timeout)      timeout="$2"; shift 2 ;;
      --prompt-max)   prompt_max="$2"; shift 2 ;;
      --response-max) response_max="$2"; shift 2 ;;
      *) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ "${#prompt}" -gt "$prompt_max" ]; then
    printf '[cmux v5] prompt size %d > %d\n' "${#prompt}" "$prompt_max" >&2
    return 2
  fi
  surface="$(_cmux_v5_resolve "$surface")" || return 6
  _cmux_v5_dispatch "$surface" "$prompt" "$mode" "$timeout" "$response_max"
}

# ---- async fire-and-collect API ----

# 송신만. fifo 생성 + cmux send. stdout=job_id, stderr=status.
# cmux_send <surface> <prompt> [--mode llm|worker]
cmux_send() {
  if [ $# -lt 2 ]; then
    printf 'usage: cmux_send <surface> <prompt> [--mode llm|worker]\n' >&2
    return 2
  fi
  local surface="$1" prompt="$2" mode=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      *) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ "${#prompt}" -gt "$CMUX_V5_PROMPT_MAX" ]; then
    printf '[cmux v5] prompt size %d > PROMPT_MAX=%d\n' "${#prompt}" "$CMUX_V5_PROMPT_MAX" >&2
    return 2
  fi

  surface="$(_cmux_v5_resolve "$surface")" || return 6

  if [ -z "$mode" ]; then
    mode="$(_cmux_v5_detect "$surface")"
  fi
  if [ "$mode" = "unknown" ]; then
    printf '[cmux v5] cannot auto-detect sidecar on %s. use --mode llm|worker.\n' \
      "$surface" >&2
    return 3
  fi

  local job fifo
  job="$(_cmux_v5_job "$surface")"
  fifo="$(_cmux_v5_make_fifo "$job")" || { printf '[cmux v5] mkfifo failed\n' >&2; return 4; }

  local full
  case "$mode" in
    llm)    full="$(_cmux_v5_llm_prompt    "$prompt" "$fifo" "$job")" ;;
    worker) full="$(_cmux_v5_worker_prompt "$prompt" "$fifo")" ;;
    *) printf '[cmux v5] bad mode: %s\n' "$mode" >&2; rm -f "$fifo"; return 2 ;;
  esac

  if ! _cmux_v5_send "$surface" "$full"; then
    printf '[cmux v5] cmux send failed (surface=%s)\n' "$surface" >&2
    rm -f "$fifo"
    return 5
  fi

  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    printf '[cmux v5] %s (%s) sent, job=%s\n' "$surface" "$mode" "$job" >&2
  fi
  printf '%s' "$job"
}

# 단일 FIFO 회수 (내부). stale = surface 사라짐 → unlink + rc 0 (스킵, 본문 없음).
# FIFO 무응답 시 CMUX_V5_FALLBACK_SCREEN=on 이면 read-screen 마커 추출 fallback.
# stdout=본문, stderr=status. rc=read_fifo rc 또는 0(stale skipped / screen 회수).
_cmux_v5_collect_one() {
  local fifo="$1" timeout="$2" rmax="$3"
  local name surface job
  name="${fifo##*/}"
  job="${name%.res}"
  surface="$(_cmux_v5_fifo_to_surface "$name")"

  if [ -n "$surface" ] && ! _cmux_v5_surface_alive "$surface"; then
    rm -f "$fifo"
    if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
      printf '[cmux v5] stale %s — surface %s gone, unlinked\n' "$job" "$surface" >&2
    fi
    return 0
  fi

  local out rc start elapsed mark
  start=$(date +%s)
  out="$(_cmux_v5_read_fifo_dynamic "$fifo" "$surface" "" "$timeout" "$rmax")"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  rm -f "$fifo"

  # Fallback: FIFO 무응답이고 surface 알면 screen 마커 추출 시도.
  local used_screen=0
  if [ "${CMUX_V5_FALLBACK_SCREEN:-off}" = "on" ] \
     && { [ "$rc" -ne 0 ] || [ "${#out}" -eq 0 ]; } \
     && [ -n "$surface" ]; then
    local token screen_out
    token="$(_cmux_v5_screen_token "$job")"
    screen_out="$(_cmux_v5_screen_extract "$surface" "$token")"
    if [ -n "$screen_out" ]; then
      # rmax 캡 적용
      if [ "${#screen_out}" -gt "$rmax" ]; then
        out="${screen_out:0:$rmax}"
      else
        out="$screen_out"
      fi
      rc=0
      used_screen=1
    fi
  fi

  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    case "$rc" in
      0)   mark="ok" ;;
      124) mark="timeout" ;;
      125) mark="early_idle" ;;
      *)   mark="rc=$rc" ;;
    esac
    [ "$used_screen" -eq 1 ] && mark="$mark,screen-fallback"
    if [ "$rc" -eq 0 ] && [ "${#out}" -ge "$rmax" ]; then mark="$mark,truncated"; fi
    if [ -n "$surface" ]; then
      printf '[cmux v5] collect %s (%s) %ds %dB %s\n' "$surface" "$job" "$elapsed" "${#out}" "$mark" >&2
    else
      printf '[cmux v5] collect %s %ds %dB %s\n' "$job" "$elapsed" "${#out}" "$mark" >&2
    fi
  fi
  printf '%s' "$out"
  return $rc
}

# cmux_collect [target] [--timeout N] [--response-max N]
#   target:
#     생략              → /tmp/cmux-fifo/ 의 모든 pending 순차 회수 (헤더로 구분)
#     surface:N         → 해당 surface 의 가장 최근 pending 1개
#     <title>           → title resolve → 위
#     <full-job>        → 기존 동작 (해당 FIFO 직접)
#   stale (surface gone) FIFO 는 자동 unlink + 스킵.
cmux_collect() {
  local target="" timeout="$CMUX_V5_TIMEOUT" rmax="$CMUX_V5_RESPONSE_MAX"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)      timeout="$2"; shift 2 ;;
      --response-max) rmax="$2"; shift 2 ;;
      --) shift; break ;;
      -*) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
      *) if [ -z "$target" ]; then target="$1"; shift; else
           printf '[cmux v5] unexpected positional: %s\n' "$1" >&2; return 2
         fi ;;
    esac
  done

  # Mode 1: no target → multi-collect 모든 pending
  if [ -z "$target" ]; then
    _cmux_v5_init_dir
    local found=0 worst=0 fifo
    for fifo in "$CMUX_V5_FIFO_DIR"/*.res; do
      [ -e "$fifo" ] || continue
      # FIFO 가 아닌 잔재 (regular file 등) 는 그냥 unlink + 스킵.
      if [ ! -p "$fifo" ]; then
        rm -f "$fifo"
        if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
          printf '[cmux v5] non-fifo leftover unlinked: %s\n' "${fifo##*/}" >&2
        fi
        continue
      fi
      found=1
      local nm surface title hdr
      nm="${fifo##*/}"
      surface="$(_cmux_v5_fifo_to_surface "$nm")"
      title=""
      [ -n "$surface" ] && title="$(_cmux_v5_surface_title "$surface")"
      if [ -n "$title" ]; then hdr="$title ($surface)"
      elif [ -n "$surface" ]; then hdr="$surface"
      else hdr="${nm%.res}"; fi
      printf '=== %s ===\n' "$hdr"
      _cmux_v5_collect_one "$fifo" "$timeout" "$rmax"
      local rc=$?
      printf '\n'
      [ "$rc" -ne 0 ] && worst="$rc"
    done
    if [ "$found" -eq 0 ]; then
      printf '[cmux v5] no pending jobs in %s\n' "$CMUX_V5_FIFO_DIR" >&2
      return 6
    fi
    return "$worst"
  fi

  # Mode 2: target 이 full-job (FIFO 가 정확히 존재)
  local direct_fifo
  direct_fifo="$(_cmux_v5_fifo_path "$target")"
  if [ -p "$direct_fifo" ]; then
    _cmux_v5_collect_one "$direct_fifo" "$timeout" "$rmax"
    return $?
  fi

  # Mode 3/4: surface:N 또는 title → 가장 최근 pending
  local surface
  surface="$(_cmux_v5_resolve "$target")" || return 6
  local fifo
  fifo="$(_cmux_v5_pick_fifo "$surface")" || {
    printf '[cmux v5] no pending job for %s\n' "$surface" >&2
    return 6
  }
  _cmux_v5_collect_one "$fifo" "$timeout" "$rmax"
}

# non-blocking 체크. rc: 0=data ready, 1=not yet (or timed out), 2=no such job.
# cmux_check <job> [--wait N] [--poll-interval F]
#   --wait N         : N초까지 폴링 후에도 안 도착이면 rc=1. 도착 즉시 rc=0.
#   --poll-interval F: 폴링 주기 (기본 0.2s)
cmux_check() {
  [ $# -ge 1 ] || { printf 'usage: cmux_check <job> [--wait N] [--poll-interval F]\n' >&2; return 2; }
  local job="$1" wait_s=0 interval=0.2
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait)          wait_s="$2"; shift 2 ;;
      --poll-interval) interval="$2"; shift 2 ;;
      *) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local fifo
  fifo="$(_cmux_v5_fifo_path "$job")"
  [ -p "$fifo" ] || return 2
  perl - "$fifo" "$wait_s" "$interval" <<'PERL'
use Time::HiRes qw(time sleep);
my ($fifo, $wait_s, $interval) = @ARGV;
my $deadline = time + $wait_s;
while (1) {
  # FIFO를 직접 open하지 않고, lsof로 이 FIFO를 open하고 있는 프로세스(writer)가 있는지 확인 (Destructive race condition 방지)
  my $lsof = `lsof -t "$fifo" 2>/dev/null`;
  if ($lsof) {
    exit 0;
  }
  last if time >= $deadline;
  sleep $interval;
}
exit 1;
PERL
}

# line 단위 stream until EOF (sidecar 가 fifo close).
# --persistent 모드를 기본 제공하여, sidecar가 redirection >> 을 반복해도 조기 EOF로 끝나지 않도록 함.
# cmux_tail <job> [--timeout N]
cmux_tail() {
  [ $# -ge 1 ] || { printf 'usage: cmux_tail <job> [--timeout N]\n' >&2; return 2; }
  local job="$1" timeout="$CMUX_V5_TIMEOUT"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      *) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local fifo
  fifo="$(_cmux_v5_fifo_path "$job")"
  if [ ! -p "$fifo" ]; then
    printf '[cmux v5] no such job: %s\n' "$job" >&2
    return 6
  fi

  # surface와 tty를 획득하여 Perl에 넘겨줘서 sidecar의 활성 상태 감지
  local surface tty short
  surface="$(_cmux_v5_fifo_to_surface "$fifo")"
  if [ -n "$surface" ]; then
    tty="$(_cmux_v5_get_tree \
      | awk -v s="$surface" '
          $0 ~ s {
            if (match($0, /tty=[^ ]+/)) {
              print substr($0, RSTART+4, RLENGTH-4); exit
            }
          }')"
    if [ -n "$tty" ]; then
      short="${tty##/dev/}"
    fi
  fi

  perl - "$timeout" "$fifo" "$short" <<'PERL'
my ($timeout, $fifo, $short) = @ARGV;
# stdout 즉시 flush — sidecar 가 line 한 줄 흘릴 때마다 화면에 보임 (true streaming).
$| = 1;
STDOUT->autoflush(1) if STDOUT->can("autoflush");
$SIG{ALRM} = sub { print STDERR "[cmux v5] tail timeout\n"; exit 124 };
alarm $timeout;

my $n = 0;
my $deadline = time() + $timeout;

while (time() < $deadline) {
  # FIFO open 시도. writer가 올 때까지 block.
  if (open(my $fh, "<", $fifo)) {
    while (defined(my $line = <$fh>)) {
      print $line;
      $n++;
    }
    close $fh;
  }
  
  # sidecar 가 완전히 작업을 끝냈는지 감시
  if ($short) {
    my $procs = `ps -ww -t "$short" -o args= 2>/dev/null` // "";
    # active process가 없으면 (쉘만 있으면) 스트리밍 종료
    my @active = grep { $_ !~ m{(^|/)(zsh|bash|sh|fish|dash|ksh|tcsh)( |$)} && $_ !~ /ps -ww/ } split(/\n/, $procs);
    if (@active == 0) {
      last;
    }
  } else {
    # TTY 감지 불가 시 한 번의 read 후 루프 종료 (backward-compat)
    last;
  }
  
  select(undef, undef, undef, 0.1); # 100ms sleep
}
alarm 0;
# stdout 완전 flush 보장 후 stderr done 메시지 — 표시 순서 직관적.
STDOUT->flush() if STDOUT->can("flush");
print STDERR "[cmux v5] tail done, $n lines\n";
exit 0;
PERL
  local rc=$?
  rm -f "$fifo"
  return $rc
}

# 진행 중 job 취소. fifo unlink + (optional) sidecar 에 ESC.
# cmux_cancel <job> [--surface X]
cmux_cancel() {
  [ $# -ge 1 ] || { printf 'usage: cmux_cancel <job> [--surface X]\n' >&2; return 2; }
  local job="$1" surface=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --surface) surface="$2"; shift 2 ;;
      *) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local fifo esc_note=""
  fifo="$(_cmux_v5_fifo_path "$job")"
  [ -p "$fifo" ] && rm -f "$fifo"
  if [ -n "$surface" ]; then
    surface="$(_cmux_v5_resolve "$surface")" || return 6
    cmux send-key --surface "$surface" Escape >/dev/null 2>&1 && esc_note=" + ESC sent"
  fi
  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    printf '[cmux v5] cancel %s (fifo unlinked%s)\n' "$job" "$esc_note" >&2
  fi
}

# cmux_by_title <title> <prompt> [opts]  — backward-compat alias.
# v5.1 부터 cmux_ask / cmux_send 가 title 인자를 직접 받으므로 신규 호출은
# `cmux_ask "<title>" "<prompt>"` 권장.
cmux_by_title() {
  [ $# -ge 2 ] || { printf 'usage: cmux_by_title <title> <prompt> [opts]\n' >&2; return 2; }
  cmux_ask "$@"
}

# v3 helper 유지 — 같은 workspace 의 다른 surface 목록
cmux_other_surfaces() {
  local tree workspace
  tree="$(_cmux_v5_get_tree_focused)" || return 1
  workspace="$(printf '%s\n' "$tree" \
    | awk '/here/ { for (i=1;i<=NF;i++) if ($i ~ /workspace:[0-9]+/) { print $i; exit } }')"
  [ -z "$workspace" ] && return 1
  printf '%s\n' "$tree" \
    | awk -v ws="$workspace" -v self="${CMUX_SURFACE_ID:-}" '
        /workspace:[0-9]+/ {
          if (match($0, /workspace:[0-9]+/)) {
            cur_ws = substr($0, RSTART, RLENGTH)
          }
        }
        cur_ws == ws && /surface:[0-9]+/ {
          if (match($0, /surface:[0-9]+/)) {
            s = substr($0, RSTART, RLENGTH)
            if (self == "" || index($0, self) == 0) print s
          }
        }
      ' | sort -u
}

# cmux_cross <target> [analyzer] <prompt> [--rounds N]
#   target  : 토론/수행 주체 (예: codex)
#   analyzer: 검토/분석 주체 (예: claude). 생략 시 다른 LLM surface 자동 탐색. 없으면 target과 동일 (Self-Refinement 모드)
#   prompt  : 최초 지시 사항
cmux_cross() {
  if [ $# -lt 2 ]; then
    printf 'usage: cmux_cross <target> [analyzer] <prompt> [--rounds N]\n' >&2
    return 2
  fi
  
  local target="$1" analyzer="" prompt="" rounds=3
  shift
  
  # 만약 두 번째 인자가 --로 시작하지 않고, 세 번째 인자가 존재하면 analyzer로 판단
  if [[ "$1" != -* ]] && [ $# -ge 2 ]; then
    analyzer="$1"
    prompt="$2"
    shift 2
  else
    prompt="$1"
    shift 1
  fi
  
  while [ $# -gt 0 ]; do
    case "$1" in
      --rounds) rounds="$2"; shift 2 ;;
      *) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  
  # target resolve
  target="$(_cmux_v5_resolve "$target")" || return 6
  
  # analyzer 자동 탐색
  if [ -z "$analyzer" ]; then
    # target이 아니고 본인(CMUX_SURFACE_ID)도 아닌 다른 LLM surface 탐색
    local other
    for other in $(cmux_other_surfaces); do
      local resolved_other
      resolved_other="$(_cmux_v5_resolve "$other")"
      if [ "$resolved_other" != "$target" ] && [ "$resolved_other" != "${CMUX_SURFACE_ID:-}" ]; then
        local mode
        mode="$(_cmux_v5_detect "$resolved_other")"
        if [ "$mode" = "llm" ]; then
          analyzer="$resolved_other"
          break
        fi
      fi
    done
    # 마땅한 analyzer가 없으면 target 본인을 analyzer로 설정 (Self-Refinement 모드)
    if [ -z "$analyzer" ]; then
      analyzer="$target"
      if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
        printf '[cmux v5] no other LLM surface found. fallback to Self-Refinement mode on %s\n' "$target" >&2
      fi
    fi
  else
    analyzer="$(_cmux_v5_resolve "$analyzer")" || return 6
  fi
  
  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    printf '[cmux v5] starting cmux_cross: target=%s, analyzer=%s, rounds=%d\n' "$target" "$analyzer" "$rounds" >&2
  fi
  
  local res="" feedback=""
  
  # Round 0: 최초 송신
  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    printf '[cmux v5] [Round 0] Sending initial prompt to %s...\n' "$target" >&2
  fi
  res=$(cmux_ask "$target" "$prompt") || return $?
  
  local i
  for ((i=1; i<=rounds; i++)); do
    # Round i-1 검토 및 피드백 생성
    local feedback_prompt
    if [ "$analyzer" = "$target" ]; then
      # Self-Refinement 피드백 프롬프트
      feedback_prompt="[cmux_cross Self-Refinement Round $i/$rounds]
이전 답변을 제공하셨습니다:
$res

현재 작업 폴더의 코드베이스를 다시 정밀 검토하여, 위 답변의 잠재적인 오류, 누락된 엣지 케이스, 또는 아키텍처적 개선점 3가지를 스스로 도출하고 더 나은 개선안을 제시해 주세요."
    else
      # 제3자 분석 피드백 프롬프트
      feedback_prompt="[cmux_cross Feedback Round $i/$rounds]
상대방($target)이 최초 지시사항에 대해 아래와 같이 답변했습니다:
$res

현재 작업 폴더의 코드베이스 사실 관계와 대조 분석하여, 상대방 답변의 오류, 개선 포인트, 혹은 추가 요구사항을 구체적으로 지적하는 피드백 의견을 작성해 주세요."
    fi
    
    if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
      printf '[cmux v5] [Round %d] Requesting review from %s...\n' "$i" "$analyzer" >&2
    fi
    feedback=$(cmux_ask "$analyzer" "$feedback_prompt") || return $?
    
    # 피드백을 반영하여 target이 재답변
    local target_prompt
    if [ "$analyzer" = "$target" ]; then
      target_prompt="[cmux_cross Self-Refinement Round $i/$rounds]
스스로 분석한 개선 사항 및 피드백은 다음과 같습니다:
$feedback

위 피드백과 개선 방향을 전면적으로 반영하여, 코드베이스 사실에 입각한 더 완벽한 결과물을 재작성해 주세요."
    else
      target_prompt="[cmux_cross Feedback Round $i/$rounds]
검토자($analyzer)로부터 다음과 같은 분석 피드백을 수신했습니다:
$feedback

위 피드백 지적 사항을 정밀 반영하여, 더 완벽한 코드베이스 개선안을 작성해 주세요."
    fi
    
    if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
      printf '[cmux v5] [Round %d] Sending feedback back to %s...\n' "$i" "$target" >&2
    fi
    res=$(cmux_ask "$target" "$target_prompt") || return $?
  done
  
  # 최종 요약 및 결론 도출
  local final_prompt
  if [ "$analyzer" = "$target" ]; then
    final_prompt="[cmux_cross Final Summary]
$rounds 회에 걸친 자가 개선(Self-Refinement)이 완료되었습니다.
현재 최종 상태를 정리하고, 초기 버전 대비 어떤 점이 개선되었는지 핵심 요약을 포함하여 최종 결과물을 깔끔하게 요약해 주세요.

[최종 답변]
$res"
  else
    final_prompt="[cmux_cross Final Summary]
상대방($target)과의 $rounds 회 토론이 완료되었습니다.
상대방의 최종 개선안과 이에 대한 귀하의 분석 결과를 토대로, 최종 코드베이스 개선 결론 및 요약을 마크다운 문서 형식으로 깔끔하게 작성해 주세요.

[상대방 최종 답변]
$res"
  fi
  
  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    printf '[cmux v5] Synthesizing final summary via %s...\n' "$analyzer" >&2
  fi
  cmux_ask "$analyzer" "$final_prompt"
}
