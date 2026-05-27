#!/usr/bin/env bash
# suf v5 — FIFO 응답 채널 + cap-discipline + auto-detect (LLM | worker)
#
# 변경점 (vs v3/v4):
#  - read-screen 폴링 완전 제거. 응답은 per-job FIFO blocking read.
#  - sidecar 정체 자동 감지 (claude/codex/gemini/pi/.. = llm, zsh/bash/.. = worker).
#  - 4종 cap 강제 (prompt size / response size / timeout / auto-cap 문구).
#  - suf_ask 는 기본 안전, suf_ask_unsafe 는 명시적 escape valve.
#
# Public:  suf_ask  suf_ask_unsafe  suf_send  suf_collect  suf_check  suf_tail  suf_cancel  suf_by_title  suf_other_surfaces
#
# 사용:
#   source /path/to/suf-v5-lib.sh
#   ANSWER=$(suf_ask "Claude Main" "현재 브랜치만 알려줘")  # title 자동 매핑
#   ANSWER=$(suf_ask surface:4 "git log -5 --oneline" --mode worker)  # surface ref 도 유지

# ---- defaults (env override 가능) ----
: "${SUF_V5_PROMPT_MAX:=500}"      # prompt 글자 cap
: "${SUF_V5_RESPONSE_MAX:=4096}"   # 응답 바이트 cap
: "${SUF_V5_TIMEOUT:=30}"          # blocking read 초
: "${SUF_V5_AUTO_CAP:=on}"         # on|off — prompt 끝에 안내문 자동 첨부
: "${SUF_V5_FIFO_DIR:=/tmp/suf-fifo}"

# ---- private ----

_suf_v5_job() {
  printf '%s-%s-%s' \
    "$(date +%s%N)" \
    "$$" \
    "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

_suf_v5_fifo_path() {
  printf '%s/%s.res' "$SUF_V5_FIFO_DIR" "$1"
}

_suf_v5_init_dir() {
  [ -d "$SUF_V5_FIFO_DIR" ] && return 0
  mkdir -p "$SUF_V5_FIFO_DIR" && chmod 700 "$SUF_V5_FIFO_DIR"
}

_suf_v5_make_fifo() {
  local job="$1" fifo
  fifo="$(_suf_v5_fifo_path "$job")"
  _suf_v5_init_dir || return 1
  rm -f "$fifo"
  mkfifo -m 0600 "$fifo" || return 1
  printf '%s' "$fifo"
}

# echo: llm | worker | unknown
_suf_v5_detect() {
  local surface="$1" tty short leader args

  # surface ref → tty. surface UUID 도 cmux tree 가 표시하므로 substring match
  tty="$(cmux tree --all 2>/dev/null \
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

_suf_v5_llm_prompt() {
  local body="$1" fifo="$2"
  if [ "$SUF_V5_AUTO_CAP" = "on" ]; then
    cat <<EOF
$body

[규칙]
- 답변은 caveman 스킬사용해서 답변할것
- 답 작성 후 마지막 도구 호출로 다음 실행 (Bash tool):
  printf '%s' "<답변_본문>" > $fifo
- 본문은 fifo 에만작성
EOF
  else
    printf '%s\n' "$body"
  fi
}

_suf_v5_worker_prompt() {
  local body="$1" fifo="$2"
  if [ "$SUF_V5_AUTO_CAP" = "on" ]; then
    # body 가 단일 shell command. 그대로 redirect.
    printf '{ %s ; } > %s 2>&1\n' "$body" "$fifo"
  else
    printf '%s\n' "$body"
  fi
}

_suf_v5_send() {
  local surface="$1" full="$2"
  # send 와 send-key 가 별개 RPC. 데몬 처리 race 로 Enter 가 본문보다 먼저
  # 도착 / 휘발할 수 있어 짧은 stall + 재시도 패턴.
  cmux send --surface "$surface" -- "$full" >/dev/null 2>&1 || return 1
  sleep "${SUF_V5_ENTER_DELAY:-0.15}"
  cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || return 1
  # Enter 휘발 보험. 빈 라인 한 번 더 — sidecar 입력창에 무해.
  if [ "${SUF_V5_ENTER_DOUBLE:-on}" = "on" ]; then
    sleep 0.05
    cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || true
  fi
}

# stdout: surface ref. 입력이 surface:* 이면 그대로, 아니면 title exact → fuzzy 순으로 resolve.
# rc: 0=ok, 5=no match / cmux tree fail, 7=ambiguous title
_suf_v5_resolve_surface() {
  local target="$1" rows matches count

  case "$target" in
    surface:*) printf '%s\n' "$target"; return 0 ;;
  esac

  rows="$(cmux tree --all 2>/dev/null \
    | awk '
        /surface:[^ ]+/ {
          ref = ""; title = "";
          if (match($0, /surface:[^ ]+/)) ref = substr($0, RSTART, RLENGTH);
          if (match($0, /"[^"]*"/)) title = substr($0, RSTART+1, RLENGTH-2);
          if (ref != "" && title != "") printf "%s\t%s\n", ref, title;
        }')"
  if [ -z "$rows" ]; then
    printf '[suf v5] cannot read cmux surfaces while resolving title: %s\n' "$target" >&2
    return 5
  fi

  # 1) exact title match
  matches="$(printf '%s\n' "$rows" | awk -F '\t' -v q="$target" '$2 == q { print }')"
  count="$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n + 0 }')"

  # 2) unique case-insensitive substring match
  if [ "$count" -eq 0 ]; then
    matches="$(printf '%s\n' "$rows" \
      | awk -F '\t' -v q="$target" 'BEGIN { lq = tolower(q) } index(tolower($2), lq) > 0 { print }')"
    count="$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n + 0 }')"
  fi

  case "$count" in
    1)
      printf '%s\n' "$matches" | awk -F '\t' 'NR == 1 { print $1 }'
      return 0
      ;;
    0)
      printf '[suf v5] no surface title matches: %s\n' "$target" >&2
      return 5
      ;;
    *)
      printf '[suf v5] ambiguous surface title: %s\n' "$target" >&2
      printf '%s\n' "$matches" | awk -F '\t' '{ printf "  %s\t%s\n", $1, $2 }' >&2
      return 7
      ;;
  esac
}

# blocking read with hard timeout (perl alarm) + byte cap.
# stdout: 본문, stderr: 경고, exit: 0=ok, 124=timeout, 5=open fail
_suf_v5_read_fifo() {
  local fifo="$1" timeout="$2" max="$3"
  perl - "$timeout" "$fifo" "$max" <<'PERL'
my ($timeout, $fifo, $max) = @ARGV;
$SIG{ALRM} = sub {
  print STDERR "[suf v5] timeout after ${timeout}s\n";
  exit 124;
};
alarm $timeout;
open(my $fh, "<", $fifo) or do {
  print STDERR "[suf v5] open fail: $!\n";
  exit 5;
};
my $buf = "";
my $remaining = $max + 0;
while ($remaining > 0) {
  my $r = sysread $fh, my $chunk, $remaining;
  if (!defined $r) {
    print STDERR "[suf v5] read err: $!\n";
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

# 공통 dispatcher (cap 검사 이후 호출됨)
_suf_v5_dispatch() {
  local surface="$1" prompt="$2" mode="$3" timeout="$4" rmax="$5"

  if [ -z "$mode" ]; then
    mode="$(_suf_v5_detect "$surface")"
  fi
  if [ "$mode" = "unknown" ]; then
    printf '[suf v5] cannot auto-detect sidecar on %s. use --mode llm|worker.\n' \
      "$surface" >&2
    return 3
  fi
  if [ "$mode" != "llm" ] && [ "$mode" != "worker" ]; then
    printf '[suf v5] bad mode: %s\n' "$mode" >&2
    return 2
  fi

  local job fifo
  job="$(_suf_v5_job)"
  fifo="$(_suf_v5_make_fifo "$job")" || {
    printf '[suf v5] mkfifo failed\n' >&2; return 4
  }

  local full
  case "$mode" in
    llm)    full="$(_suf_v5_llm_prompt    "$prompt" "$fifo")" ;;
    worker) full="$(_suf_v5_worker_prompt "$prompt" "$fifo")" ;;
  esac

  if ! _suf_v5_send "$surface" "$full"; then
    printf '[suf v5] cmux send failed (surface=%s)\n' "$surface" >&2
    rm -f "$fifo"
    return 5
  fi

  local out rc start elapsed mark
  start=$(date +%s)
  out="$(_suf_v5_read_fifo "$fifo" "$timeout" "$rmax")"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  rm -f "$fifo"

  # stderr 한 줄 status (default on, SUF_V5_QUIET=on 으로 끔)
  if [ "${SUF_V5_QUIET:-off}" != "on" ]; then
    case "$rc" in
      0)   mark="ok" ;;
      124) mark="timeout" ;;
      *)   mark="rc=$rc" ;;
    esac
    if [ "$rc" -eq 0 ] && [ "${#out}" -ge "$rmax" ]; then
      mark="$mark,truncated"
    fi
    printf '[suf v5] %s (%s) %ds %dB %s\n' \
      "$surface" "$mode" "$elapsed" "${#out}" "$mark" >&2
  fi

  printf '%s' "$out"
  return $rc
}

# ---- public ----

# suf_ask <surface-or-title> <prompt> [--mode llm|worker] [--timeout N]
suf_ask() {
  if [ $# -lt 2 ]; then
    printf 'usage: suf_ask <surface-or-title> <prompt> [--mode llm|worker] [--timeout N]\n' >&2
    return 2
  fi
  local target="$1" surface prompt="$2" mode="" timeout="$SUF_V5_TIMEOUT"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)    mode="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      *) printf '[suf v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ "${#prompt}" -gt "$SUF_V5_PROMPT_MAX" ]; then
    printf '[suf v5] prompt size %d > PROMPT_MAX=%d. use suf_ask_unsafe if intentional.\n' \
      "${#prompt}" "$SUF_V5_PROMPT_MAX" >&2
    return 2
  fi
  surface="$(_suf_v5_resolve_surface "$target")" || return $?
  _suf_v5_dispatch "$surface" "$prompt" "$mode" "$timeout" "$SUF_V5_RESPONSE_MAX"
}

# suf_ask_unsafe — cap 우회. 큰 응답이 의도적임을 호출자가 선언.
# suf_ask_unsafe <surface-or-title> <prompt> [--mode ...] [--timeout N]
#                         [--prompt-max N] [--response-max N]
suf_ask_unsafe() {
  if [ $# -lt 2 ]; then
    printf 'usage: suf_ask_unsafe <surface-or-title> <prompt> [opts]\n' >&2
    return 2
  fi
  local target="$1" surface prompt="$2" mode="" \
    timeout="$SUF_V5_TIMEOUT" prompt_max=99999 response_max=$((1024*1024))
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)         mode="$2"; shift 2 ;;
      --timeout)      timeout="$2"; shift 2 ;;
      --prompt-max)   prompt_max="$2"; shift 2 ;;
      --response-max) response_max="$2"; shift 2 ;;
      *) printf '[suf v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ "${#prompt}" -gt "$prompt_max" ]; then
    printf '[suf v5] prompt size %d > %d\n' "${#prompt}" "$prompt_max" >&2
    return 2
  fi
  surface="$(_suf_v5_resolve_surface "$target")" || return $?
  _suf_v5_dispatch "$surface" "$prompt" "$mode" "$timeout" "$response_max"
}

# ---- async fire-and-collect API ----

# 송신만. fifo 생성 + cmux send. stdout=job_id, stderr=status.
# suf_send <surface-or-title> <prompt> [--mode llm|worker]
suf_send() {
  if [ $# -lt 2 ]; then
    printf 'usage: suf_send <surface-or-title> <prompt> [--mode llm|worker]\n' >&2
    return 2
  fi
  local target="$1" surface prompt="$2" mode=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      *) printf '[suf v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ "${#prompt}" -gt "$SUF_V5_PROMPT_MAX" ]; then
    printf '[suf v5] prompt size %d > PROMPT_MAX=%d\n' "${#prompt}" "$SUF_V5_PROMPT_MAX" >&2
    return 2
  fi

  surface="$(_suf_v5_resolve_surface "$target")" || return $?

  if [ -z "$mode" ]; then
    mode="$(_suf_v5_detect "$surface")"
  fi
  if [ "$mode" = "unknown" ]; then
    printf '[suf v5] cannot auto-detect sidecar on %s. use --mode llm|worker.\n' \
      "$surface" >&2
    return 3
  fi

  local job fifo
  job="$(_suf_v5_job)"
  fifo="$(_suf_v5_make_fifo "$job")" || { printf '[suf v5] mkfifo failed\n' >&2; return 4; }

  local full
  case "$mode" in
    llm)    full="$(_suf_v5_llm_prompt    "$prompt" "$fifo")" ;;
    worker) full="$(_suf_v5_worker_prompt "$prompt" "$fifo")" ;;
    *) printf '[suf v5] bad mode: %s\n' "$mode" >&2; rm -f "$fifo"; return 2 ;;
  esac

  if ! _suf_v5_send "$surface" "$full"; then
    printf '[suf v5] cmux send failed (surface=%s)\n' "$surface" >&2
    rm -f "$fifo"
    return 5
  fi

  if [ "${SUF_V5_QUIET:-off}" != "on" ]; then
    printf '[suf v5] %s (%s) sent, job=%s\n' "$surface" "$mode" "$job" >&2
  fi
  printf '%s' "$job"
}

# fifo blocking read. stdout=본문, stderr=status, rc=read_fifo rc.
# suf_collect <job> [--timeout N] [--response-max N]
suf_collect() {
  if [ $# -lt 1 ]; then
    printf 'usage: suf_collect <job> [--timeout N] [--response-max N]\n' >&2
    return 2
  fi
  local job="$1" timeout="$SUF_V5_TIMEOUT" rmax="$SUF_V5_RESPONSE_MAX"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)      timeout="$2"; shift 2 ;;
      --response-max) rmax="$2"; shift 2 ;;
      *) printf '[suf v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local fifo
  fifo="$(_suf_v5_fifo_path "$job")"
  if [ ! -p "$fifo" ]; then
    printf '[suf v5] no such job: %s\n' "$job" >&2
    return 6
  fi

  local out rc start elapsed mark
  start=$(date +%s)
  out="$(_suf_v5_read_fifo "$fifo" "$timeout" "$rmax")"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  rm -f "$fifo"

  if [ "${SUF_V5_QUIET:-off}" != "on" ]; then
    case "$rc" in
      0)   mark="ok" ;;
      124) mark="timeout" ;;
      *)   mark="rc=$rc" ;;
    esac
    if [ "$rc" -eq 0 ] && [ "${#out}" -ge "$rmax" ]; then mark="$mark,truncated"; fi
    printf '[suf v5] collect %s %ds %dB %s\n' "$job" "$elapsed" "${#out}" "$mark" >&2
  fi
  printf '%s' "$out"
  return $rc
}

# non-blocking 체크. rc: 0=data ready, 1=not yet (or timed out), 2=no such job.
# suf_check <job> [--wait N] [--poll-interval F]
#   --wait N         : N초까지 폴링 후에도 안 도착이면 rc=1. 도착 즉시 rc=0.
#   --poll-interval F: 폴링 주기 (기본 0.2s)
suf_check() {
  [ $# -ge 1 ] || { printf 'usage: suf_check <job> [--wait N] [--poll-interval F]\n' >&2; return 2; }
  local job="$1" wait_s=0 interval=0.2
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait)          wait_s="$2"; shift 2 ;;
      --poll-interval) interval="$2"; shift 2 ;;
      *) printf '[suf v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local fifo
  fifo="$(_suf_v5_fifo_path "$job")"
  [ -p "$fifo" ] || return 2
  perl - "$fifo" "$wait_s" "$interval" <<'PERL'
use Fcntl qw(O_RDONLY O_NONBLOCK);
use IO::Select;
use Time::HiRes qw(time sleep);
my ($fifo, $wait_s, $interval) = @ARGV;
my $deadline = time + $wait_s;
while (1) {
  sysopen(my $fh, $fifo, O_RDONLY | O_NONBLOCK) or exit 2;
  my $s = IO::Select->new($fh);
  if ($s->can_read(0)) { close $fh; exit 0; }
  close $fh;
  last if time >= $deadline;
  sleep $interval;
}
exit 1;
PERL
}

# line 단위 stream until EOF (sidecar 가 fifo close).
# 한 writer 로 line print + close 패턴에서만 작동.
# suf_tail <job> [--timeout N]
suf_tail() {
  [ $# -ge 1 ] || { printf 'usage: suf_tail <job> [--timeout N]\n' >&2; return 2; }
  local job="$1" timeout="$SUF_V5_TIMEOUT"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      *) printf '[suf v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local fifo
  fifo="$(_suf_v5_fifo_path "$job")"
  if [ ! -p "$fifo" ]; then
    printf '[suf v5] no such job: %s\n' "$job" >&2
    return 6
  fi
  perl - "$timeout" "$fifo" <<'PERL'
my ($timeout, $fifo) = @ARGV;
# stdout 즉시 flush — sidecar 가 line 한 줄 흘릴 때마다 화면에 보임 (true streaming).
$| = 1;
STDOUT->autoflush(1) if STDOUT->can("autoflush");
$SIG{ALRM} = sub { print STDERR "[suf v5] tail timeout\n"; exit 124 };
alarm $timeout;
open(my $fh, "<", $fifo) or do { print STDERR "[suf v5] tail open fail: $!\n"; exit 5 };
my $n = 0;
while (defined(my $line = <$fh>)) {
  print $line;
  $n++;
}
alarm 0;
close $fh;
# stdout 완전 flush 보장 후 stderr done 메시지 — 표시 순서 직관적.
STDOUT->flush() if STDOUT->can("flush");
print STDERR "[suf v5] tail done, $n lines\n";
exit 0;
PERL
  local rc=$?
  rm -f "$fifo"
  return $rc
}

# 진행 중 job 취소. fifo unlink + (optional) sidecar 에 ESC.
# suf_cancel <job> [--surface X]
suf_cancel() {
  [ $# -ge 1 ] || { printf 'usage: suf_cancel <job> [--surface X]\n' >&2; return 2; }
  local job="$1" surface=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --surface) surface="$2"; shift 2 ;;
      *) printf '[suf v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local fifo esc_note=""
  fifo="$(_suf_v5_fifo_path "$job")"
  [ -p "$fifo" ] && rm -f "$fifo"
  if [ -n "$surface" ]; then
    cmux send-key --surface "$surface" Escape >/dev/null 2>&1 && esc_note=" + ESC sent"
  fi
  if [ "${SUF_V5_QUIET:-off}" != "on" ]; then
    printf '[suf v5] cancel %s (fifo unlinked%s)\n' "$job" "$esc_note" >&2
  fi
}

# suf_by_title <title> <prompt> [--mode llm|worker] [--timeout N]
#   호환용 wrapper. 이제 suf_ask/suf_send 첫 인자도 title 을 직접 받는다.
suf_by_title() {
  [ $# -ge 2 ] || { printf 'usage: suf_by_title <title> <prompt> [opts]\n' >&2; return 2; }
  local title="$1" prompt="$2"; shift 2
  suf_ask "$title" "$prompt" "$@"
}

# v3 helper 유지 — 같은 workspace 의 다른 surface 목록
suf_other_surfaces() {
  local tree workspace
  tree="$(cmux tree 2>/dev/null)" || return 1
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
