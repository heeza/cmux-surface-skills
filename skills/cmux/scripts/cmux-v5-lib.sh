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
: "${CMUX_V5_TREE_TTL:=3}"          # cmux tree 캐시 TTL(초). resolve→detect→dynamic 간 tree fork 재사용
: "${CMUX_V5_FIFO_DIR:=/tmp/cmux-fifo}"
: "${CMUX_V5_FALLBACK_SCREEN:=off}" # on|off — FIFO 무응답 시 read-screen 마커 추출 fallback
: "${CMUX_V5_SCREEN_LINES:=200}"    # fallback 추출 시 read-screen 라인 수
: "${CMUX_V5_PROMPT_STYLE:=compact}" # compact|verbose — LLM 수신 규칙 길이
: "${CMUX_V5_EARLY_IDLE:=off}"      # off|worker|llm|on — 실패 조기 감지용 polling
: "${CMUX_V5_POLL_INTERVAL:=1}"     # early-idle polling 간격
: "${CMUX_V5_LOCK_DIR:=/tmp/cmux-locks}"   # advisory lock 디렉터리
: "${CMUX_V5_LOCK_TTL:=300}"               # stale lock 판정 초(소유 PID 사망 OR age>TTL)
: "${CMUX_V5_LOCK_WAIT:=10}"               # acquire 재시도 최대 대기 초
: "${CMUX_V5_JOB_DIR:=/tmp/cmux-jobs}"     # job 레지스트리 루트
: "${CMUX_V5_JOB_TTL_MIN:=720}"            # job 레코드 GC 분(기본 12h)
: "${CMUX_V5_FLOW_MAX_NODES:=64}"          # cmux_flow DAG 노드 안전 상한

# ---- private ----

_CMUX_V5_TREE_CACHE=""
_CMUX_V5_TREE_CACHE_TIME=0
_CMUX_V5_TREE_FOCUSED_CACHE=""
_CMUX_V5_TREE_FOCUSED_CACHE_TIME=0
_CMUX_V5_GC_DONE=0
_CMUX_V5_JOBGC_DONE=0

_cmux_v5_get_tree() {
  local now
  now=$(date +%s)
  if [ -n "$_CMUX_V5_TREE_CACHE" ] && [ $((now - _CMUX_V5_TREE_CACHE_TIME)) -lt "${CMUX_V5_TREE_TTL:-3}" ]; then
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
  if [ -n "$_CMUX_V5_TREE_FOCUSED_CACHE" ] && [ $((now - _CMUX_V5_TREE_FOCUSED_CACHE_TIME)) -lt "${CMUX_V5_TREE_TTL:-3}" ]; then
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
  # 12시간(720분) 이상 방치된 FIFO 파일들을 백그라운드에서 조용히 정리.
  # send/collect 마다 find 를 fork 하지 않도록 셸 세션당 1회만 수행.
  [ "$_CMUX_V5_GC_DONE" = "1" ] && return 0
  _CMUX_V5_GC_DONE=1
  find "$CMUX_V5_FIFO_DIR" -type p -mmin +720 -delete 2>/dev/null &
  # stale lock 디렉터리 백스톱 정리: ts-file 내용 기반 stale 은 acquire 시 break 하므로
  # 여기선 디렉터리 mtime 이 TTL 보다 오래된 *.lock 만 coarse 하게 제거.
  [ -d "$CMUX_V5_LOCK_DIR" ] && find "$CMUX_V5_LOCK_DIR" -type d -name '*.lock' -mmin +$(( ${CMUX_V5_LOCK_TTL:-300} / 60 + 1 )) -exec rm -rf {} + 2>/dev/null &
}

_cmux_v5_init_dir() {
  [ -d "$CMUX_V5_FIFO_DIR" ] && { _cmux_v5_garbage_collect; return 0; }
  mkdir -p "$CMUX_V5_FIFO_DIR" && chmod 700 "$CMUX_V5_FIFO_DIR"
  _cmux_v5_garbage_collect
}

# ---- 이식형 advisory lock (mkdir 기반 mutex, stat 의존 X) ----

# _cmux_v5_lock_path <name> -> 락 디렉터리 경로
_cmux_v5_lock_path() { printf '%s/%s.lock' "$CMUX_V5_LOCK_DIR" "$1"; }

# _cmux_v5_lock_is_stale <lockpath> -> stale 이면 0, 아니면 1.
#   판정: 소유 PID 명시적 사망 OR (now - ts > TTL).
#   ts 파일을 직접 읽어 비교하므로 stat 의 BSD/GNU 차이를 회피.
#   주의: 락 획득은 mkdir → pid 기록 → ts 기록 순서(아래 _cmux_v5_lock)라,
#   "막 태어나는 중"인 락은 pid 가 (대개) 살아있고 ts 만 잠깐 비어 있다.
#   따라서 dead-pid 를 먼저 보고, 그 다음 빈/비정상 ts 는 stale 가 아니라
#   '점유 중'으로 간주해야 born-window 경합(빈 ts 를 stale 로 오판→타 프로세스가
#   살아있는 락을 rm 후 이중 획득)을 차단한다. pid 기록 전 크래시처럼
#   pid·ts 모두 없는 진짜 좀비는 GC 의 mtime 백스톱이 정리한다.
_cmux_v5_lock_is_stale() {
  local lockpath="$1" pid ts now ttl
  ttl="${CMUX_V5_LOCK_TTL:-300}"
  pid="$(cat "$lockpath/pid" 2>/dev/null)"
  # 소유 PID 가 기록돼 있고 그게 죽었으면 ts 유무와 무관하게 stale
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  ts="$(cat "$lockpath/ts" 2>/dev/null)"
  # ts 가 비었거나 숫자가 아니면 = 막 태어나는 중(혹은 GC 가 처리) → 점유로 간주
  case "$ts" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now="$(date +%s)"
  if [ $((now - ts)) -gt "$ttl" ]; then
    return 0
  fi
  return 1
}

# _cmux_v5_lock <name> [wait_secs]
#   atomic mkdir 으로 락 획득. 점유 중이면 stale 검사→break 후 1회 재시도,
#   아니면 0.2s 간격으로 wait_secs 까지 폴링. 성공 0, 타임아웃 1.
#   획득 시 pid/ts 메타를 락 디렉터리 안에 기록.
_cmux_v5_lock() {
  local name="$1" wait_secs="${2:-${CMUX_V5_LOCK_WAIT:-10}}"
  local lockpath now deadline
  # 빈/슬래시 포함 name 은 락 디렉터리 밖 경로를 유발하므로 거부
  case "$name" in ''|*/*) return 1 ;; esac
  lockpath="$(_cmux_v5_lock_path "$name")"
  # 락 루트 디렉터리 lazy init
  mkdir -p "$CMUX_V5_LOCK_DIR" 2>/dev/null && chmod 700 "$CMUX_V5_LOCK_DIR" 2>/dev/null
  deadline=$(( $(date +%s) + wait_secs ))
  while :; do
    # 핵심 mutex: 기존 디렉터리면 mkdir 가 원자적으로 실패.
    if mkdir "$lockpath" 2>/dev/null; then
      printf '%s' "$$" > "$lockpath/pid" 2>/dev/null
      date +%s > "$lockpath/ts" 2>/dev/null
      return 0
    fi
    # 점유 중 — stale 이면 break 후 1회 재시도.
    if _cmux_v5_lock_is_stale "$lockpath"; then
      rm -rf "$lockpath" 2>/dev/null
      if mkdir "$lockpath" 2>/dev/null; then
        printf '%s' "$$" > "$lockpath/pid" 2>/dev/null
        date +%s > "$lockpath/ts" 2>/dev/null
        return 0
      fi
    fi
    # 마감 시각 초과면 타임아웃.
    now="$(date +%s)"
    [ "$now" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# _cmux_v5_unlock <name>
#   소유 PID($$) 일치할 때만 제거(타 프로세스 락 오삭제 방지). 항상 0 반환.
_cmux_v5_unlock() {
  local name="$1" lockpath pid
  case "$name" in ''|*/*) return 0 ;; esac
  lockpath="$(_cmux_v5_lock_path "$name")"
  pid="$(cat "$lockpath/pid" 2>/dev/null)"
  if [ "$pid" = "$$" ]; then
    rm -rf "$lockpath" 2>/dev/null
  fi
  return 0
}

# ---- job 레지스트리 ----
# DAG 스케줄러가 소비할 토대. 기존 public 함수/FIFO 동작과 완전 독립인 additive 레이어.
# 디스크 레이아웃:
#   $CMUX_V5_JOB_DIR/<jobid>/
#     meta          # KEY=VALUE 라인 (grep 가능, JSON 이스케이프 회피)
#     state         # 단일 토큰 (빠른 읽기용, meta 와 중복 저장)
#     result        # 응답 본문 raw (이스케이프 없이 verbatim)
#     events.ndjson # 한 줄당 {"ts":N,"from":"S","to":"S"} (필드가 통제되어 hand-built JSON 안전)
# meta 파싱 규칙: 읽기는 `^KEY=` 첫 매치 라인을 grep 후 prefix strip.
#   upsert 는 lock 하에 그 키 라인을 제외하고 재작성 후 KEY=VALUE 추가(temp+mv 원자 교체).
#   값은 단일 라인만 허용(개행 포함 시 거부).

# 유효 상태 집합. terminal: DONE FAILED CANCELLED.
_CMUX_V5_JOB_STATES="PENDING DISPATCHING RUNNING DONE FAILED CANCELLED"

# new_state 가 enum 에 속하면 0, 아니면 1.
# zsh 는 unquoted $var 를 word-split 하지 않으므로(bash 와 차이), for-in 대신
# 양쪽 끝을 공백으로 패딩한 case 매칭으로 토큰 포함 여부를 셸 무관하게 판정한다.
_cmux_v5_job_valid_state() {
  case " $_CMUX_V5_JOB_STATES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# _cmux_v5_job_dir <jobid> -> $CMUX_V5_JOB_DIR/<jobid>. 빈/슬래시 jobid 거부(rc 1).
_cmux_v5_job_dir() {
  local jobid="$1"
  case "$jobid" in ''|*/*) return 1 ;; esac
  printf '%s/%s' "$CMUX_V5_JOB_DIR" "$jobid"
}

# _cmux_v5_job_new <jobid> <target> [deps] [deadline]
#   job 디렉터리 + meta + state=PENDING + 빈 result + 최초 이벤트(from="" to="PENDING") 생성.
#   lock 으로 create race 차단. 이미 존재하면 clobber 없이 rc 1.
_cmux_v5_job_new() {
  local jobid="$1" target="$2" deps="${3:-}" deadline="${4:-}"
  local dir created now
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  # 단일 라인 보장: target/deps/deadline 에 개행 있으면 거부 (락 획득 전).
  case "$target$deps$deadline" in *"
"*) return 1 ;; esac
  _cmux_v5_lock "job-$jobid" || return 1
  if [ -d "$dir" ]; then
    _cmux_v5_unlock "job-$jobid"
    return 1
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    _cmux_v5_unlock "job-$jobid"
    return 1
  fi
  created="$(date +%s)"
  now="$created"
  {
    printf 'id=%s\n' "$jobid"
    printf 'target=%s\n' "$target"
    printf 'prompt_hash=\n'
    printf 'deps=%s\n' "$deps"
    printf 'state=PENDING\n'
    printf 'attempts=0\n'
    printf 'created=%s\n' "$created"
    printf 'deadline=%s\n' "$deadline"
  } > "$dir/meta"
  printf 'PENDING' > "$dir/state.tmp" && mv -f "$dir/state.tmp" "$dir/state"
  : > "$dir/result"
  printf '{"ts":%s,"from":"","to":"PENDING"}\n' "$now" > "$dir/events.ndjson"
  _cmux_v5_unlock "job-$jobid"
  return 0
}

# _cmux_v5_job_get <jobid> <key> -> meta 의 KEY 값(없으면 빈). 단일 라인 원자 읽기라 lock 불필요.
_cmux_v5_job_get() {
  local jobid="$1" key="$2" dir line
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  [ -f "$dir/meta" ] || return 0
  line="$(grep "^${key}=" "$dir/meta" 2>/dev/null | head -1)"
  [ -z "$line" ] && return 0
  printf '%s' "${line#*=}"
}

# _cmux_v5_job_state <jobid> -> state 파일의 현재 토큰(없으면 빈).
_cmux_v5_job_state() {
  local jobid="$1" dir
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  [ -f "$dir/state" ] || return 0
  cat "$dir/state" 2>/dev/null
}

# _cmux_v5_job_set_meta <jobid> <key> <value>
#   meta 의 KEY=VALUE 라인을 lock 하에 upsert(없으면 추가, 있으면 교체). 정확히 한 줄 보장.
#   key 에 '=' 또는 개행 포함 시 rc 2. value 에 개행 포함 시 rc 2.
_cmux_v5_job_set_meta() {
  local jobid="$1" key="$2" value="$3" dir
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  case "$key" in *'='*|*"
"*) return 2 ;; esac
  case "$value" in *"
"*) return 2 ;; esac
  [ -d "$dir" ] || return 1
  _cmux_v5_lock "job-$jobid" || return 1
  # grep -v 는 전부 필터되면 rc 1 → && 체이닝 금지(단일키 파일에서 abort 방지).
  grep -v "^${key}=" "$dir/meta" 2>/dev/null > "$dir/meta.tmp"
  printf '%s=%s\n' "$key" "$value" >> "$dir/meta.tmp"
  mv -f "$dir/meta.tmp" "$dir/meta"
  _cmux_v5_unlock "job-$jobid"
  return 0
}

# _cmux_v5_job_set_state <jobid> <new_state>
#   enum 검증(아니면 rc 2). lock 하에 old 읽기 → state 파일 + meta state= 둘 다 갱신 →
#   events.ndjson 에 이벤트 추가. 동일 상태 재기록도 이벤트를 그대로 append 한다(idempotent 비강제).
_cmux_v5_job_set_state() {
  local jobid="$1" new_state="$2" dir old now
  _cmux_v5_job_valid_state "$new_state" || return 2
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  [ -d "$dir" ] || return 1
  _cmux_v5_lock "job-$jobid" || return 1
  old="$(cat "$dir/state" 2>/dev/null)"
  now="$(date +%s)"
  # state 파일도 temp+mv 로 원자 교체 — lock-free reader 의 torn read 차단.
  printf '%s' "$new_state" > "$dir/state.tmp" && mv -f "$dir/state.tmp" "$dir/state"
  # meta 의 state= 라인 upsert (lock 재진입 회피 위해 인라인 처리).
  grep -v "^state=" "$dir/meta" 2>/dev/null > "$dir/meta.tmp"
  printf 'state=%s\n' "$new_state" >> "$dir/meta.tmp"
  mv -f "$dir/meta.tmp" "$dir/meta"
  printf '{"ts":%s,"from":"%s","to":"%s"}\n' "$now" "$old" "$new_state" >> "$dir/events.ndjson"
  _cmux_v5_unlock "job-$jobid"
  return 0
}

# _cmux_v5_job_incr_attempts <jobid> -> lock 하에 attempts+1 기록. 새 카운트 출력.
_cmux_v5_job_incr_attempts() {
  local jobid="$1" dir cur next line
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  [ -d "$dir" ] || return 1
  _cmux_v5_lock "job-$jobid" || return 1
  line="$(grep "^attempts=" "$dir/meta" 2>/dev/null | head -1)"
  cur="${line#*=}"
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  next=$((cur + 1))
  grep -v "^attempts=" "$dir/meta" 2>/dev/null > "$dir/meta.tmp"
  printf 'attempts=%s\n' "$next" >> "$dir/meta.tmp"
  mv -f "$dir/meta.tmp" "$dir/meta"
  _cmux_v5_unlock "job-$jobid"
  printf '%s' "$next"
}

# _cmux_v5_job_set_result <jobid> <body> -> result 파일에 body verbatim 기록(단일 writer 가정, 안전상 lock).
_cmux_v5_job_set_result() {
  local jobid="$1" body="$2" dir
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  [ -d "$dir" ] || return 1
  _cmux_v5_lock "job-$jobid" || return 1
  # result 도 원자 교체 — lock-free get_result 의 torn read 차단.
  printf '%s' "$body" > "$dir/result.tmp" && mv -f "$dir/result.tmp" "$dir/result"
  _cmux_v5_unlock "job-$jobid"
  return 0
}

# _cmux_v5_job_get_result <jobid> -> result 파일 cat(없으면 빈).
_cmux_v5_job_get_result() {
  local jobid="$1" dir
  dir="$(_cmux_v5_job_dir "$jobid")" || return 1
  [ -f "$dir/result" ] || return 0
  cat "$dir/result" 2>/dev/null
}

# _cmux_v5_job_list [state] -> jobid(디렉터리 basename) 출력. state 인자 시 그 상태만 필터.
_cmux_v5_job_list() {
  local filter="${1:-}" d base st
  [ -d "$CMUX_V5_JOB_DIR" ] || return 0
  for d in "$CMUX_V5_JOB_DIR"/*; do
    [ -d "$d" ] || continue
    base="${d##*/}"
    if [ -n "$filter" ]; then
      st="$(cat "$d/state" 2>/dev/null)"
      [ "$st" = "$filter" ] || continue
    fi
    printf '%s\n' "$base"
  done
}

# _cmux_v5_job_gc -> TTL(분) 초과 job 디렉터리를 백그라운드 비차단 제거. 셸 세션당 1회만.
#   -mindepth 1 로 루트 자체 삭제 방지(BSD-safe).
_cmux_v5_job_gc() {
  [ "$_CMUX_V5_JOBGC_DONE" = "1" ] && return 0
  _CMUX_V5_JOBGC_DONE=1
  [ -d "$CMUX_V5_JOB_DIR" ] || return 0
  find "$CMUX_V5_JOB_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +"${CMUX_V5_JOB_TTL_MIN:-720}" -exec rm -rf {} + 2>/dev/null &
  return 0
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

  # LLM 우선 매칭 (LLM 이 떠 있으면 shell 도 같이 있는 게 정상).
  # 기존 4개 grep(word-anchored / anthropic·openai / node-launched / pi)을
  # 단일 -iE union 으로 통합하여 fork 4→1. case-insensitive 는 매칭을 넓힐 뿐 의미 동일.
  if printf '%s' "$procs" | grep -qiE \
      '(^|/)(claude|codex|gemini|opencode|omc|omo|omx|agy|antigravity|junie|pi)( |$)|anthropic|openai|node .*(claude|codex|gemini|agy|antigravity)'; then
    echo llm; return 0
  fi

  # LLM 흔적 없음 → shell 이면 worker. zsh/bash/.. 와 일반 sh 를 단일 union 으로 (fork 2→1).
  if printf '%s' "$procs" | grep -qE '(^|/| )(zsh|bash|fish|dash|ksh|tcsh)( |$)|(^|/)sh( |$)'; then
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
1. Bash 호출 가능하면 마지막 Bash 호출로 답변을 FIFO 에 기록 (chat 출력 X). 가운데 줄을 실제 답으로 교체, 비우지 말 것:
    cat > $fifo <<'$delim'
    여기에 실제 답변 작성 (이 줄을 너의 답으로 교체)
    $delim
2. Bash 호출 불가하면 chat 에 아래 두 마커 사이에 실제 답을 출력:
   === CMUX_${token}_BEGIN ===
   여기에 실제 답변
   === CMUX_${token}_END ===
- 답변은 간결하게.
EOF
      else
        cat <<EOF
$body

[cmux]
반드시 마지막 Bash 도구 호출 1번으로 답변을 FIFO 에만 기록. chat 출력 금지.
가운데 줄을 너의 실제 답변으로 교체하라 — 절대 비워두지 말 것:
cat > $fifo <<'$delim'
여기에 실제 답변 작성 (이 줄을 너의 답으로 교체)
$delim
답변은 간결하게.
EOF
      fi
    elif [ "$CMUX_V5_FALLBACK_SCREEN" = "on" ] && [ -n "$token" ]; then
      cat <<EOF
$body

[cmux] 답을 짧게. 가능하면 마지막 Bash 호출로 FIFO 에만 기록 — 가운데 줄을 실제 답으로 교체, 비우지 말 것:
cat > $fifo <<'$delim'
여기에 실제 답변 작성 (이 줄을 너의 답으로 교체)
$delim
Bash 불가하면 chat 에 아래 두 마커 사이에 실제 답을 출력:
=== CMUX_${token}_BEGIN ===
여기에 실제 답변
=== CMUX_${token}_END ===
EOF
    else
      cat <<EOF
$body

[cmux] 위 질문의 답을 짧게. 반드시 마지막 Bash 도구 호출 1번으로 아래 명령을 실행해 FIFO 파일에만 기록하라(chat 출력 금지). 첫/마지막 줄(구분자 $delim)은 그대로 두고, 가운데 줄을 너의 실제 답변으로 교체하라 — 절대 비워두지 말 것:
cat > $fifo <<'$delim'
여기에 실제 답변 작성 (이 줄을 너의 답으로 교체)
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
            # EOF: writer 가 connect 후 close. macOS/BSD NONBLOCK FIFO 의미론상
            # select->can_read 는 writer 가 실제로 접속한 뒤에만 readable 을 보고하므로,
            # buf 가 비어 있는 EOF 도 "완료된 빈 응답"으로 즉시 처리한다 (rc=0).
            # (재오픈하여 더 기다리면 side-effect-only worker·no-match grep·빈 응답이
            #  timeout 까지 hang 되는 회귀가 발생하므로 절대 reopen 하지 않는다.)
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

  # Mode 1: no target → multi-collect 모든 pending.
  # 각 job 을 background 로 병렬 회수 → 총 대기시간 = max(개별) (기존 sum 대비 대폭 단축).
  # zsh/bash 호환을 위해 셸 배열 대신 인덱스 파일($tmpd/$n.*) 사용.
  if [ -z "$target" ]; then
    _cmux_v5_init_dir
    # zsh(nomatch ON)에서 빈 디렉토리 glob 이 함수를 abort 시키지 않도록 (bash 에선 무관).
    # LOCAL_OPTIONS 로 함수 종료 시 원복.
    [ -n "${ZSH_VERSION:-}" ] && setopt local_options no_nomatch 2>/dev/null
    local tmpd
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cmux-collect.XXXXXX")" || {
      printf '[cmux v5] mktemp failed\n' >&2; return 1
    }
    # 지역변수 1회 선언 (zsh: 값 있는 변수의 무대입 `local` 재선언은 stdout 오염).
    local found=0 n=0 fifo nm surface title hdr
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
      n=$((n+1))
      nm="${fifo##*/}"
      surface="$(_cmux_v5_fifo_to_surface "$nm")"
      title=""
      [ -n "$surface" ] && title="$(_cmux_v5_surface_title "$surface")"
      if [ -n "$title" ]; then hdr="$title ($surface)"
      elif [ -n "$surface" ]; then hdr="$surface"
      else hdr="${nm%.res}"; fi
      printf '%s' "$hdr" > "$tmpd/$n.hdr"
      # body→$n.out, status(stderr)→$n.err, rc→$n.rc 로 격리 후 background 회수.
      ( _cmux_v5_collect_one "$fifo" "$timeout" "$rmax" > "$tmpd/$n.out" 2> "$tmpd/$n.err"
        printf '%s' "$?" > "$tmpd/$n.rc" ) &
    done

    if [ "$found" -eq 0 ]; then
      rm -rf "$tmpd"
      printf '[cmux v5] no pending jobs in %s\n' "$CMUX_V5_FIFO_DIR" >&2
      return 6
    fi

    # collector 완료 대기 — 각 collector 가 마지막에 쓴 .rc sentinel 개수로 판정.
    # `wait <pid>` 는 zsh 에서 이미 종료된 자식에 'job not found' 를 내므로 비사용.
    # find 로 세어 glob nomatch 회피. 우리 tmpd 만 보므로 GC find·무관한 잡과 격리됨.
    local _bdl=$(( $(date +%s) + timeout + 5 ))
    while [ "$(find "$tmpd" -maxdepth 1 -name '*.rc' 2>/dev/null | wc -l | tr -d ' ')" -lt "$n" ]; do
      [ "$(date +%s)" -ge "$_bdl" ] && break
      sleep 0.1
    done

    # 원래 발견 순서대로 헤더/본문 출력 + worst rc 집계.
    local worst=0 i=1 rc
    while [ "$i" -le "$n" ]; do
      [ -s "$tmpd/$i.err" ] && cat "$tmpd/$i.err" >&2
      printf '=== %s ===\n' "$(cat "$tmpd/$i.hdr" 2>/dev/null)"
      [ -f "$tmpd/$i.out" ] && cat "$tmpd/$i.out"
      printf '\n'
      rc=0
      [ -f "$tmpd/$i.rc" ] && rc="$(cat "$tmpd/$i.rc" 2>/dev/null)"
      [ "$rc" -ne 0 ] && worst="$rc"
      i=$((i+1))
    done
    rm -rf "$tmpd"
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
  local tree
  tree="$(_cmux_v5_get_tree_focused)" || return 1
  # 계층 트리를 단일 패스로 파싱: workspace 를 라인 진행에 따라 추적하고,
  # 'here' 마커가 달린 surface(=self)와 그 workspace 를 식별한 뒤,
  # 같은 workspace 의 다른 surface 만 출력한다. self 식별은 신뢰 불가한
  # CMUX_SURFACE_ID(UUID) 대신 here 마커로 한다.
  printf '%s\n' "$tree" \
    | awk '
        match($0, /workspace:[0-9]+/) { cur = substr($0, RSTART, RLENGTH); next }
        match($0, /surface:[0-9]+/) {
          s = substr($0, RSTART, RLENGTH)
          n++; order[n] = s; ws[s] = cur
          if ($0 ~ /(^| )here( |$)/) { here_ws = cur; here_s = s }
        }
        END {
          if (here_ws == "") exit 0
          for (i = 1; i <= n; i++) {
            s = order[i]
            if (ws[s] == here_ws && s != here_s && !seen[s]++) print s
          }
        }'
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

  # 라운드마다 직전 답변($res/$feedback)을 프롬프트에 임베드하므로 cmux_ask 의
  # PROMPT_MAX=500 캡에 걸려 전체가 중단됨 → 내부 호출은 cmux_ask_unsafe 로 우회.
  # 응답은 CROSS_RESPONSE_MAX 로 캡하여 라운드 누적에 따른 토큰 무한증식을 차단.
  local cross_pmax=1000000
  local cross_rmax="${CMUX_V5_CROSS_RESPONSE_MAX:-16384}"

  # 두 번째 인자(분석자 후보)와 세 번째 인자(프롬프트) 모두 옵션(--)이 아닐 때만 analyzer로 판단
  if [[ "$1" != -* ]] && [[ "${2:-}" != -* ]] && [ $# -ge 2 ]; then
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
    # (zsh: 값 있는 변수의 무대입 `local` 재선언은 stdout 오염 → 루프 밖 1회 선언)
    local other resolved_other mode
    for other in $(cmux_other_surfaces); do
      resolved_other="$(_cmux_v5_resolve "$other")"
      if [ "$resolved_other" != "$target" ] && [ "$resolved_other" != "${CMUX_SURFACE_ID:-}" ]; then
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
  res=$(cmux_ask_unsafe "$target" "$prompt" --prompt-max "$cross_pmax" --response-max "$cross_rmax") || return $?
  
  local i feedback_prompt target_prompt
  for ((i=1; i<=rounds; i++)); do
    # Round i-1 검토 및 피드백 생성 (지역변수는 루프 밖에서 1회 선언; zsh stdout 오염 방지)
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
    feedback=$(cmux_ask_unsafe "$analyzer" "$feedback_prompt" --prompt-max "$cross_pmax" --response-max "$cross_rmax") || return $?
    
    # 피드백을 반영하여 target이 재답변
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
    res=$(cmux_ask_unsafe "$target" "$target_prompt" --prompt-max "$cross_pmax" --response-max "$cross_rmax") || return $?
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
  cmux_ask_unsafe "$analyzer" "$final_prompt" --prompt-max "$cross_pmax" --response-max "$cross_rmax"
}

# cmux_broadcast <prompt> [target ...] [--mode m] [--timeout N] [--response-max N]
#   멀티 에이전트 fan-out/fan-in. 지정한 대상(생략 시 같은 workspace 의 다른 LLM surface 전체)에
#   동일 prompt 를 async 송신 후 병렬 수신한다. 응답은 surface 당 response-max 로 캡되어 토큰이 bound 되고,
#   1-shot(라운드 없음)이라 무한 토큰 소요가 없다. cmux_cross(토론)와 달리 단순 동시 질의용.
#   prompt 는 짧은 ask 용으로 PROMPT_MAX 캡을 따른다.
cmux_broadcast() {
  if [ $# -lt 1 ]; then
    printf 'usage: cmux_broadcast <prompt> [target ...] [--mode m] [--timeout N] [--response-max N]\n' >&2
    return 2
  fi
  local prompt="$1"; shift
  # 모든 지역변수를 여기서 1회만 선언한다. zsh 는 값이 있는 변수를 `local`(대입 없이)로
  # 재선언하면 'name=value' 를 stdout 에 출력하므로(typeset 표시 동작), 루프/블록 안에서
  # 재선언하면 응답에 쓰레기가 섞인다. 따라서 절대 재선언하지 않는다.
  local mode="" timeout="$CMUX_V5_TIMEOUT" rmax="$CMUX_V5_RESPONSE_MAX" targets=""
  local s rs t job n=0 sent=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)         mode="$2"; shift 2 ;;
      --timeout)      timeout="$2"; shift 2 ;;
      --response-max) rmax="$2"; shift 2 ;;
      --) shift; break ;;
      -*) printf '[cmux v5] unknown arg: %s\n' "$1" >&2; return 2 ;;
      *)  targets="${targets}${1}
"; shift ;;
    esac
  done
  if [ "${#prompt}" -gt "$CMUX_V5_PROMPT_MAX" ]; then
    printf '[cmux v5] prompt size %d > PROMPT_MAX=%d (broadcast 는 짧은 ask 용)\n' \
      "${#prompt}" "$CMUX_V5_PROMPT_MAX" >&2
    return 2
  fi

  # 대상 미지정 → 같은 workspace 의 다른 LLM surface 자동 수집
  if [ -z "$targets" ]; then
    for s in $(cmux_other_surfaces); do
      rs="$(_cmux_v5_resolve "$s" 2>/dev/null)" || continue
      [ -n "${CMUX_SURFACE_ID:-}" ] && [ "$rs" = "$CMUX_SURFACE_ID" ] && continue
      if [ "$(_cmux_v5_detect "$rs")" = "llm" ]; then
        targets="${targets}${rs}
"
      fi
    done
  fi
  if [ -z "$targets" ]; then
    printf '[cmux v5] broadcast: no target LLM surface found\n' >&2
    return 6
  fi

  local tmpd
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cmux-bcast.XXXXXX")" || {
    printf '[cmux v5] mktemp failed\n' >&2; return 1
  }

  # 1) async fan-out — 각 대상에 비동기 송신, job 기록 (지역변수는 상단에서 이미 선언)
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    rs="$(_cmux_v5_resolve "$t" 2>/dev/null)" || {
      printf '[cmux v5] broadcast: cannot resolve %s, skip\n' "$t" >&2; continue; }
    if [ -n "$mode" ]; then
      job="$(cmux_send "$rs" "$prompt" --mode "$mode" 2>/dev/null)"
    else
      job="$(cmux_send "$rs" "$prompt" 2>/dev/null)"
    fi
    [ -z "$job" ] && { printf '[cmux v5] broadcast: send failed on %s, skip\n' "$rs" >&2; continue; }
    n=$((n+1))
    printf '%s' "$rs"  > "$tmpd/$n.ref"
    printf '%s' "$job" > "$tmpd/$n.job"
    sent=$((sent+1))
  done <<EOF
$targets
EOF

  if [ "$sent" -eq 0 ]; then
    rm -rf "$tmpd"
    printf '[cmux v5] broadcast: no send succeeded\n' >&2
    return 5
  fi
  if [ "${CMUX_V5_QUIET:-off}" != "on" ]; then
    printf '[cmux v5] broadcast: fan-out to %d surface(s), collecting in parallel...\n' "$sent" >&2
  fi

  # 2) parallel fan-in — job 단위 background 수집
  local i=1
  while [ "$i" -le "$n" ]; do
    if [ -f "$tmpd/$i.job" ]; then
      ( cmux_collect "$(cat "$tmpd/$i.job")" --timeout "$timeout" --response-max "$rmax" \
          > "$tmpd/$i.out" 2> "$tmpd/$i.err"
        printf '%s' "$?" > "$tmpd/$i.rc" ) &
    fi
    i=$((i+1))
  done
  # collector 완료 대기 — .rc sentinel 개수로 판정 (zsh `wait <pid>` 'job not found' 회피,
  # glob nomatch 회피, 우리 tmpd 만 보므로 무관한 잡과 격리).
  local _bdl=$(( $(date +%s) + timeout + 5 ))
  while [ "$(find "$tmpd" -maxdepth 1 -name '*.rc' 2>/dev/null | wc -l | tr -d ' ')" -lt "$sent" ]; do
    [ "$(date +%s)" -ge "$_bdl" ] && break
    sleep 0.1
  done

  # 3) 송신 순서대로 헤더/본문 출력 + worst rc 집계
  local worst=0 rc title ref
  i=1
  while [ "$i" -le "$n" ]; do
    ref="$(cat "$tmpd/$i.ref" 2>/dev/null)"
    title="$(_cmux_v5_surface_title "$ref" 2>/dev/null)"
    [ -s "$tmpd/$i.err" ] && cat "$tmpd/$i.err" >&2
    if [ -n "$title" ]; then printf '=== %s (%s) ===\n' "$title" "$ref"
    else printf '=== %s ===\n' "$ref"; fi
    [ -f "$tmpd/$i.out" ] && cat "$tmpd/$i.out"
    printf '\n'
    rc=0; [ -f "$tmpd/$i.rc" ] && rc="$(cat "$tmpd/$i.rc" 2>/dev/null)"
    [ "$rc" -ne 0 ] && worst="$rc"
    i=$((i+1))
  done
  rm -rf "$tmpd"
  return "$worst"
}

# ---- cmux_flow (P2 DAG 스케줄러) ----
# P1 job 레지스트리 위에 얹는 의존성 그래프 스케줄러. 기존 public 함수와 완전 독립인 additive 레이어.
# stdin (또는 파일 인자) 의 TAB 구분 DSL 을 소비:
#   <id>\t<target>\t<deps>\t<prompt>
#   - id    : [A-Za-z0-9_-]+ (그 외 거부)
#   - target: dispatch 로 그대로 전달되는 surface ref / title
#   - deps  : 쉼표 구분 node id 목록, 또는 '-' (없음)
#   - prompt: 4번째 필드부터 끝까지(내부 TAB 보존)
#   '#' 주석/빈 줄 무시.
# 동작:
#   ready node(모든 dep DONE)를 파도(wave)마다 병렬 실행. 결과는 템플릿 치환으로 dependent 에 주입.
#   실패는 격리: dep 이 FAILED/CANCELLED 인 node 는 CANCELLED 로 전파(cascade), 독립 분기는 계속.
# 모든 노드↔서브셸 통신은 on-disk 레지스트리(lock 보호)로만 이뤄지므로 background &+wait 가 안전하다.

# 프로세스 전역 카운터 — 같은 프로세스/같은 초 내 다중 cmux_flow 호출의 flowid 충돌 방지.
_CMUX_V5_FLOW_COUNTER=0

# _cmux_v5_flow_run_node <target> <prompt>
#   실제 dispatch 본체. 테스트가 override 할 수 있도록 별도 tiny 함수로 분리(cmux_ask 인라인 금지).
#   stdout=응답, rc=dispatch rc.
_cmux_v5_flow_run_node() {
  cmux_ask "$1" "$2"
}

# 콤마구분 문자열을 한 줄에 하나씩 출력(빈 토큰 제거). bash/zsh 양쪽에서 word-split 의존 없이 동작.
# printf '%s' 는 마지막 토큰에 개행을 붙이지 않으므로 read 조건에 || [ -n "$_d" ] 추가.
_cmux_v5_flow_split_deps() {
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r _d; do
    [ -n "$_d" ] && printf '%s\n' "$_d"
  done
}

# _cmux_v5_flow_exec_node <flowid> <nodeid> <target> <prompt>
#   단일 노드 실행: DISPATCHING → RUNNING → run_node 호출 → rc0 이면 result 기록 + DONE, 아니면 FAILED.
#   background 서브셸에서 호출되며, 상태/결과는 전부 레지스트리에 기록한다.
_cmux_v5_flow_exec_node() {
  local flowid="$1" nodeid="$2" target="$3" prompt="$4"
  local jobid out rc
  jobid="${flowid}__${nodeid}"
  _cmux_v5_job_set_state "$jobid" DISPATCHING
  _cmux_v5_job_set_state "$jobid" RUNNING
  # rc/stdout 위생: local 대입 분리 (zsh 무대입 재선언 stdout 오염 회피는 상단 1회 선언으로 처리).
  out="$(_cmux_v5_flow_run_node "$target" "$prompt")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    _cmux_v5_job_set_result "$jobid" "$out"
    _cmux_v5_job_set_state "$jobid" DONE
  else
    _cmux_v5_job_set_state "$jobid" FAILED
  fi
}

# _cmux_v5_flow_render <flowid> <deps> <prompt>
#   prompt 안의 {{ID.result}} 와 {{ID}} 토큰을 dep ID 의 result 로 치환(deps 만 대상).
#   bash 파라미터 확장 ${//} 라 sed-style '&' 마법 없이 임의 바이트(& \ / " 등) 안전.
#   치환된 prompt 를 stdout 으로 출력.
_cmux_v5_flow_render() {
  local flowid="$1" deps="$2" prompt="$3"
  local d r
  case "$deps" in ''|'-') printf '%s' "$prompt"; return 0 ;; esac
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    r="$(_cmux_v5_job_get_result "${flowid}__${d}")"
    # .result 형식 먼저, 그 다음 bare {{ID}}. 패턴을 quote 하여 node id 를 literal 로 매칭.
    prompt="${prompt//"{{${d}.result}}"/"$r"}"
    prompt="${prompt//"{{${d}}}"/"$r"}"
  done < <(_cmux_v5_flow_split_deps "$deps")
  printf '%s' "$prompt"
}

# cmux_flow [file]
#   stdin(또는 file 인자)에서 DAG DSL 을 읽어 파싱→사이클 검사→파도 스케줄링→최종 보고.
#   최종 stdout: 노드당 한 줄 `id\tSTATE\t<result bytes>` (위상 정렬 순).
#   rc 0 = 전 노드 DONE, rc 1 = FAILED/CANCELLED 하나라도 있음.
cmux_flow() {
  local src tmpd line id target deps prompt
  local nodes_n=0 i j

  # 0) 입력 소스 결정 (file 인자 우선, 없으면 stdin).
  if [ $# -ge 1 ] && [ -n "$1" ]; then
    if [ ! -f "$1" ]; then
      printf 'cmux_flow: no such file: %s\n' "$1" >&2
      return 2
    fi
    src="$1"
  else
    src=""
  fi

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cmux-flow.XXXXXX")" || {
    printf 'cmux_flow: mktemp failed\n' >&2; return 1
  }

  # 1) 파싱 — 노드를 인덱스별 temp 파일에 격리(zsh runtime 배열 함정 회피).
  #    각 노드: $tmpd/<i>.id  .target  .deps  .prompt
  #    중복 id 거부, id 문자셋 검증, deps='-' 정규화.
  _cmux_v5_flow_parse() {
    local _src="$1" _td="$2"
    local _id _target _deps _prompt _n=0 _k _seen
    while IFS="$(printf '\t')" read -r _id _target _deps _prompt || [ -n "$_id" ]; do
      # 빈 줄/주석 스킵.
      case "$_id" in ''|'#'*) continue ;; esac
      # id 문자셋 검증.
      case "$_id" in *[!A-Za-z0-9_-]*)
        printf 'cmux_flow: invalid node id: %s\n' "$_id" >&2; return 2 ;;
      esac
      # 중복 id 검사.
      _k=1
      while [ "$_k" -le "$_n" ]; do
        _seen="$(cat "$_td/$_k.id" 2>/dev/null)"
        if [ "$_seen" = "$_id" ]; then
          printf 'cmux_flow: duplicate node id: %s\n' "$_id" >&2; return 2
        fi
        _k=$((_k+1))
      done
      [ -z "$_deps" ] && _deps='-'
      _n=$((_n+1))
      printf '%s' "$_id"     > "$_td/$_n.id"
      printf '%s' "$_target" > "$_td/$_n.target"
      printf '%s' "$_deps"   > "$_td/$_n.deps"
      printf '%s' "$_prompt" > "$_td/$_n.prompt"
    done
    printf '%s' "$_n" > "$_td/count"
    return 0
  }

  if [ -n "$src" ]; then
    _cmux_v5_flow_parse "$src" "$tmpd" < "$src" || { rm -rf "$tmpd"; return 2; }
  else
    _cmux_v5_flow_parse "" "$tmpd" || { rm -rf "$tmpd"; return 2; }
  fi
  nodes_n="$(cat "$tmpd/count" 2>/dev/null)"
  case "$nodes_n" in ''|*[!0-9]*) nodes_n=0 ;; esac

  if [ "$nodes_n" -eq 0 ]; then
    rm -rf "$tmpd"
    printf 'cmux_flow: no nodes parsed\n' >&2
    return 2
  fi
  if [ "$nodes_n" -gt "$CMUX_V5_FLOW_MAX_NODES" ]; then
    rm -rf "$tmpd"
    printf 'cmux_flow: too many nodes (%d > MAX_NODES=%d)\n' "$nodes_n" "$CMUX_V5_FLOW_MAX_NODES" >&2
    return 2
  fi

  # 2) dep 유효성 검사 — 모든 dep 이 알려진 node id 여야 한다.
  local di dj dd one found
  i=1
  while [ "$i" -le "$nodes_n" ]; do
    dd="$(cat "$tmpd/$i.deps" 2>/dev/null)"
    case "$dd" in '-'|'') i=$((i+1)); continue ;; esac
    while IFS= read -r one; do
      [ -z "$one" ] && continue
      found=0
      j=1
      while [ "$j" -le "$nodes_n" ]; do
        if [ "$(cat "$tmpd/$j.id" 2>/dev/null)" = "$one" ]; then found=1; break; fi
        j=$((j+1))
      done
      if [ "$found" -eq 0 ]; then
        printf 'cmux_flow: unknown dep "%s" referenced by node "%s"\n' "$one" "$(cat "$tmpd/$i.id" 2>/dev/null)" >&2
        rm -rf "$tmpd"
        return 2
      fi
    done < <(_cmux_v5_flow_split_deps "$dd")
    i=$((i+1))
  done

  # 3) 위상 정렬(Kahn 동등) — 사이클 검사 + 출력 순서 결정 동시에.
  #    placed[k]=1 표시 파일 + topo 순서 리스트($tmpd/topo, 노드 인덱스 한 줄씩).
  : > "$tmpd/topo"
  local placed_n=0 progress pk pdeps pd pall pidx
  while [ "$placed_n" -lt "$nodes_n" ]; do
    progress=0
    i=1
    while [ "$i" -le "$nodes_n" ]; do
      if [ -f "$tmpd/$i.placed" ]; then i=$((i+1)); continue; fi
      pdeps="$(cat "$tmpd/$i.deps" 2>/dev/null)"
      pall=1
      case "$pdeps" in
        '-'|'') : ;;
        *)
          while IFS= read -r pd; do
            [ -z "$pd" ] && continue
            # pd 의 노드 인덱스를 찾아 placed 여부 확인.
            pidx=0
            j=1
            while [ "$j" -le "$nodes_n" ]; do
              if [ "$(cat "$tmpd/$j.id" 2>/dev/null)" = "$pd" ]; then pidx="$j"; break; fi
              j=$((j+1))
            done
            if [ "$pidx" -eq 0 ] || [ ! -f "$tmpd/$pidx.placed" ]; then pall=0; break; fi
          done < <(_cmux_v5_flow_split_deps "$pdeps")
          ;;
      esac
      if [ "$pall" -eq 1 ]; then
        : > "$tmpd/$i.placed"
        printf '%s\n' "$i" >> "$tmpd/topo"
        placed_n=$((placed_n+1))
        progress=1
      fi
      i=$((i+1))
    done
    if [ "$progress" -eq 0 ]; then
      rm -rf "$tmpd"
      printf 'cmux_flow: cycle detected\n' >&2
      return 2
    fi
  done

  # 4) flow id 할당 — epoch + $$ + 전역 카운터(같은 초/프로세스 충돌 방지). '__' 없는 single-underscore.
  _CMUX_V5_FLOW_COUNTER=$(( ${_CMUX_V5_FLOW_COUNTER:-0} + 1 ))
  local flowid
  # tmpd 의 고유 suffix(mktemp 가 보장)를 flowid seed 로 재사용하면 서브셸 간 충돌 없음.
  flowid="flow-$(basename "$tmpd")"

  # 5) 노드별 job 등록 (state=PENDING). jobid = <flowid>__<nodeid>.
  local nid ntarget ndeps njobid
  i=1
  while [ "$i" -le "$nodes_n" ]; do
    nid="$(cat "$tmpd/$i.id" 2>/dev/null)"
    ntarget="$(cat "$tmpd/$i.target" 2>/dev/null)"
    ndeps="$(cat "$tmpd/$i.deps" 2>/dev/null)"
    njobid="${flowid}__${nid}"
    if ! _cmux_v5_job_new "$njobid" "$ntarget" "$ndeps"; then
      rm -rf "$tmpd"
      printf 'cmux_flow: job registration failed for node %s\n' "$nid" >&2
      return 1
    fi
    i=$((i+1))
  done

  # 6) 파도 루프 — PENDING 이 없어질 때까지.
  #    각 패스: PENDING 노드를 스캔하여
  #      - dep 중 FAILED/CANCELLED 있음 → CANCELLED 로 전파(newly_cancelled).
  #      - 모든 dep DONE → ready (병렬 dispatch 대상).
  #    ready 가 비고 PENDING 이 남았는데 newly_cancelled 도 없으면 deadlock 가드로 break.
  local wave_ready newly_cancelled st depst rdy_i pending_left ready_cnt dep_failed dep_all_done
  while :; do
    # 아직 PENDING 인 노드가 있는지 + ready / cancel 분류.
    pending_left=0
    : > "$tmpd/ready"
    newly_cancelled=0
    i=1
    while [ "$i" -le "$nodes_n" ]; do
      njobid="${flowid}__$(cat "$tmpd/$i.id" 2>/dev/null)"
      st="$(_cmux_v5_job_state "$njobid")"
      if [ "$st" != "PENDING" ]; then i=$((i+1)); continue; fi
      pending_left=1
      ndeps="$(cat "$tmpd/$i.deps" 2>/dev/null)"
      # dep 상태 평가.
      dep_failed=0; dep_all_done=1
      case "$ndeps" in
        '-'|'') : ;;
        *)
          while IFS= read -r one; do
            [ -z "$one" ] && continue
            depst="$(_cmux_v5_job_state "${flowid}__${one}")"
            case "$depst" in
              FAILED|CANCELLED) dep_failed=1; dep_all_done=0 ;;
              DONE) : ;;
              *) dep_all_done=0 ;;
            esac
          done < <(_cmux_v5_flow_split_deps "$ndeps")
          ;;
      esac
      if [ "$dep_failed" -eq 1 ]; then
        _cmux_v5_job_set_state "$njobid" CANCELLED
        newly_cancelled=1
      elif [ "$dep_all_done" -eq 1 ]; then
        printf '%s\n' "$i" >> "$tmpd/ready"
      fi
      i=$((i+1))
    done

    # PENDING 이 더 없으면 종료.
    if [ "$pending_left" -eq 0 ]; then break; fi

    # ready 개수 확인.
    ready_cnt="$(wc -l < "$tmpd/ready" 2>/dev/null | tr -d ' ')"
    case "$ready_cnt" in ''|*[!0-9]*) ready_cnt=0 ;; esac

    if [ "$ready_cnt" -eq 0 ]; then
      # ready 없음: 이번 패스에 cancel 이 있었으면 다음 패스로 cascade, 아니면 deadlock 가드.
      if [ "$newly_cancelled" -eq 1 ]; then
        continue
      else
        break
      fi
    fi

    # ready 노드 전부 병렬 dispatch 후 wave 단위 wait.
    while IFS= read -r rdy_i; do
      [ -z "$rdy_i" ] && continue
      nid="$(cat "$tmpd/$rdy_i.id" 2>/dev/null)"
      ntarget="$(cat "$tmpd/$rdy_i.target" 2>/dev/null)"
      ndeps="$(cat "$tmpd/$rdy_i.deps" 2>/dev/null)"
      prompt="$(cat "$tmpd/$rdy_i.prompt" 2>/dev/null)"
      # 부모에서 템플릿 렌더(이 시점 dep 결과는 디스크에 존재).
      prompt="$(_cmux_v5_flow_render "$flowid" "$ndeps" "$prompt")"
      ( _cmux_v5_flow_exec_node "$flowid" "$nid" "$ntarget" "$prompt" ) &
    done < "$tmpd/ready"
    wait
  done

  # 7) 최종 보고 — topo 순서대로 id\tSTATE\t<result>. rc 집계.
  local rc_all=0 tline tnid tjobid tstate tresult
  while IFS= read -r tline; do
    [ -z "$tline" ] && continue
    tnid="$(cat "$tmpd/$tline.id" 2>/dev/null)"
    tjobid="${flowid}__${tnid}"
    tstate="$(_cmux_v5_job_state "$tjobid")"
    tresult="$(_cmux_v5_job_get_result "$tjobid")"
    printf '%s\t%s\t%d\n' "$tnid" "$tstate" "${#tresult}"
    [ "$tstate" = "DONE" ] || rc_all=1
  done < "$tmpd/topo"

  rm -rf "$tmpd"
  return "$rc_all"
}
