#!/usr/bin/env bash
# cmux-lib.sh — surface ↔ surface 통신 헬퍼
# source 해서 사용:  source ~/.agents/skills/cmux/scripts/cmux-lib.sh
#
# v3 — polling 정밀화. pipe-pane 은 TUI (Claude UI 등) 의 cursor-rewrite 를
# 못 캡처해서 false negative 가 잦았다. read-screen 으로 surface buffer 전체를
# 보되, "END 마커 횟수" 가 아니라 "닫힌 ANSWER..END pair 1개 이상" 으로 판정.
# send echo 위치 의존성 제거 — TUI/일반 shell 어디서나 동작.
#
# v4 — 대용량 payload 용 file-spool 사이드채널 추가.
# screen 은 control + 메타만, body 는 /tmp/cmux-spool/<job>.{in,out} 으로 흐름.
# scrollback cap / ANSI 손실 / 입력창 길이 한계를 모두 우회.
# cmux_ask_file (sidecar 답변을 파일로) + cmux_send_file (parent → sidecar 파일 입력).

cmux_job() {
  local rnd
  rnd=$(od -vAn -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  echo "$(date +%s%N)-$$-${rnd:-0}"
}

# cmux_say <surface> <prompt>
# 마커/ack 지시를 자동 부착해 송신. JOB 토큰을 stdout 으로 echo.
cmux_say() {
  local surface="$1" prompt="$2"
  local job
  job="$(cmux_job)"

  local full="$prompt

답변은 반드시 아래 두 마커 사이에 작성하세요 (다른 곳에 본문을 두지 마세요):
<<<CMUX_ANSWER:$job>>>
(여기에 답변 본문)
<<<CMUX_END:$job>>>"

  cmux send --surface "$surface" -- "$full" >/dev/null
  cmux send-key --surface "$surface" Enter >/dev/null
  echo "$job"
}

# 내부 헬퍼 — surface buffer 에서 닫힌 ANSWER..END pair 가 ≥ 2 개일 때
# (1개는 sidecar 가 본 prompt echo, 추가가 진짜 답변) 마지막 pair 의 본문을
# stdout 으로 출력하고 exit 0. 부족하면 빈 출력 + exit 1.
_cmux_try_extract() {
  local surface="$1" job="$2" lines="${3:-8000}"
  cmux read-screen --surface "$surface" --scrollback --lines "$lines" 2>/dev/null \
    | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
    | awk -v s="<<<CMUX_ANSWER:$job>>>" -v e="<<<CMUX_END:$job>>>" '
        index($0,s) { flag=1; buf=""; next }
        index($0,e) {
          if (flag) { last=buf; pairs++ }
          flag=0; next
        }
        flag { buf = buf $0 "\n" }
        END {
          if (pairs >= 2) { printf "%s", last; exit 0 }
          else { exit 1 }
        }
      '
}

# cmux_ask <surface> <prompt> [timeout=600]
# 송신 후 surface buffer 에 닫힌 ANSWER..END pair 가 등장할 때까지 폴링.
# 본문을 stdout 으로 출력, 실패 시 비어있고 exit 1.
cmux_ask() {
  local surface="$1" prompt="$2" timeout="${3:-600}"
  local poll="${CMUX_POLL_INTERVAL:-0.5}"
  local lines="${CMUX_READ_LINES:-8000}"

  local job
  job="$(cmux_say "$surface" "$prompt")" || return 1

  local deadline
  deadline=$(( $(date +%s) + timeout ))
  local body
  while (( $(date +%s) < deadline )); do
    body="$(_cmux_try_extract "$surface" "$job" "$lines")" && {
      # 안정화 — sidecar 가 마커 닫고 추가 출력 중일 수 있음
      sleep "${CMUX_GRACE:-0.5}"
      _cmux_try_extract "$surface" "$job" "$lines"
      return 0
    }
    sleep "$poll"
  done
  echo "[cmux] timeout: job=$job surface=$surface" >&2
  return 1
}

# ── 레거시 호환 (분리 호출) ───────────────────────────
# 새 코드는 cmux_ask 만 쓰면 됨.

# cmux_wait <surface> <job> [timeout=600]
# 닫힌 pair 1개 등장까지 폴링. exit 0 / 1.
cmux_wait() {
  local surface="$1" job="$2" timeout="${3:-600}"
  local poll="${CMUX_POLL_INTERVAL:-0.5}"
  local lines="${CMUX_READ_LINES:-8000}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    _cmux_try_extract "$surface" "$job" "$lines" >/dev/null && return 0
    sleep "$poll"
  done
  return 1
}

# cmux_hear <surface> <job> [lines=8000]
# 마지막 ANSWER..END 블록 추출 (대기 없음).
cmux_hear() {
  local surface="$1" job="$2" lines="${3:-8000}"
  _cmux_try_extract "$surface" "$job" "$lines"
}

# ── v4: file-spool 사이드채널 (대용량 payload) ──────────────
#
# 원리: screen 으로는 marker + 메타 (path/size/sha256) 만 흘리고, 본문은
# /tmp/cmux-spool/<JOB>.{in,out} 파일로 직접 교환. screen scrollback cap
# (8000~20000줄), ANSI 손실, 입력창 길이 제한이 모두 비켜감.

CMUX_SPOOL_DIR="${CMUX_SPOOL_DIR:-/tmp/cmux-spool}"

_cmux_spool_init() {
  if [ ! -d "$CMUX_SPOOL_DIR" ]; then
    mkdir -p "$CMUX_SPOOL_DIR" 2>/dev/null || return 1
  fi
  chmod 0700 "$CMUX_SPOOL_DIR" 2>/dev/null
}

_cmux_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

_cmux_size() {
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

# 닫힌 ANSWER..END pair 중 마지막 pair 에서 CMUX_FILE/SIZE/SHA256 메타 3줄을
# 추출. file 모드 prompt 는 진짜 marker 를 printf 포맷 안에 `%s` 형태로만
# 넣어 echo 에선 marker 가 substitute 되지 않으므로, echo 가 pair 를 만들지
# 않는다. 따라서 pairs ≥ 1 + CMUX_FILE 존재할 때 sidecar 응답으로 판정.
# 출력은 file\nsize\nsha 3줄.
_cmux_try_extract_file() {
  local surface="$1" job="$2" lines="${3:-8000}"
  cmux read-screen --surface "$surface" --scrollback --lines "$lines" 2>/dev/null \
    | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
    | awk -v s="<<<CMUX_ANSWER:$job>>>" -v e="<<<CMUX_END:$job>>>" '
        index($0,s) { flag=1; file=""; size=""; sha=""; have=0; next }
        index($0,e) {
          if (flag && have) { last_file=file; last_size=size; last_sha=sha; pairs++ }
          flag=0; next
        }
        flag {
          line=$0
          if (match(line, /^[[:space:]]*CMUX_FILE:[[:space:]]*/)) {
            file = substr(line, RSTART+RLENGTH)
            gsub(/[[:space:]]+$/, "", file); gsub(/\r/, "", file)
            have=1
          } else if (match(line, /^[[:space:]]*CMUX_SIZE:[[:space:]]*/)) {
            size = substr(line, RSTART+RLENGTH)
            gsub(/[[:space:]]+$/, "", size); gsub(/\r/, "", size)
          } else if (match(line, /^[[:space:]]*CMUX_SHA256:[[:space:]]*/)) {
            sha = substr(line, RSTART+RLENGTH)
            gsub(/[[:space:]]+$/, "", sha); gsub(/\r/, "", sha)
          }
        }
        END {
          if (pairs >= 1 && last_file != "") {
            print last_file
            print last_size
            print last_sha
            exit 0
          }
          exit 1
        }
      '
}

# cmux_ask_file <surface> <prompt> [timeout=600]
# sidecar 가 답변을 spool 파일에 쓰고, 마커 안에는 path+size+sha256 만 남김.
# 검증 통과 시 절대 파일 경로를 stdout 으로 echo. 호출자가 cat/파싱/삭제 책임.
# Return: 0 ok, 1 timeout, 2 file missing, 3 size mismatch, 4 sha mismatch.
cmux_ask_file() {
  local surface="$1" prompt="$2" timeout="${3:-600}"
  local poll="${CMUX_POLL_INTERVAL:-0.5}"
  local lines="${CMUX_READ_LINES:-8000}"

  _cmux_spool_init || { echo "[cmux] spool init failed: $CMUX_SPOOL_DIR" >&2; return 1; }

  local job outfile
  job="$(cmux_job)"
  outfile="$CMUX_SPOOL_DIR/$job.out"

  local full="$prompt

[cmux:file 모드] 답변 본문은 파일에 쓰고, 마커 안에는 메타데이터 3줄만 적으세요.
아래 셸 한 줄을 그대로 실행하면 자동으로 메타까지 출력됩니다 (본문만 채워서):

cat > $outfile.tmp <<'EOF_CMUX_BODY'
(여기에 답변 본문을 그대로 — 길이 제한 없음, 바이너리/JSON/문서 다 OK)
EOF_CMUX_BODY
mv $outfile.tmp $outfile && \\
  printf '<<<CMUX_ANSWER:%s>>>\\nCMUX_FILE: %s\\nCMUX_SIZE: %s\\nCMUX_SHA256: %s\\n<<<CMUX_END:%s>>>\\n' \\
    '$job' '$outfile' \"\$(wc -c < $outfile | tr -d ' ')\" \"\$(shasum -a 256 $outfile | awk '{print \$1}')\" '$job'

다른 곳에 본문이나 마커를 출력하지 마세요."

  cmux send --surface "$surface" -- "$full" >/dev/null
  cmux send-key --surface "$surface" Enter >/dev/null

  local deadline meta lf ls lsha
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if meta="$(_cmux_try_extract_file "$surface" "$job" "$lines")"; then
      sleep "${CMUX_GRACE:-0.5}"
      meta="$(_cmux_try_extract_file "$surface" "$job" "$lines")" || { sleep "$poll"; continue; }
      lf=$(printf '%s\n' "$meta" | sed -n 1p)
      ls=$(printf '%s\n' "$meta" | sed -n 2p)
      lsha=$(printf '%s\n' "$meta" | sed -n 3p)

      [ -f "$lf" ] || { echo "[cmux] file missing: $lf" >&2; return 2; }

      local actual_size actual_sha
      actual_size="$(_cmux_size "$lf")"
      if [ -n "$ls" ] && [ "$actual_size" != "$ls" ]; then
        echo "[cmux] size mismatch: declared=$ls actual=$actual_size file=$lf" >&2
        return 3
      fi
      if [ -n "$lsha" ]; then
        actual_sha="$(_cmux_sha256 "$lf")"
        if [ -n "$actual_sha" ] && [ "$actual_sha" != "$lsha" ]; then
          echo "[cmux] sha256 mismatch: declared=$lsha actual=$actual_sha file=$lf" >&2
          return 4
        fi
      fi
      echo "$lf"
      return 0
    fi
    sleep "$poll"
  done
  echo "[cmux] timeout (file mode): job=$job surface=$surface expected=$outfile" >&2
  return 1
}

# cmux_send_file <surface> <local-path> <prompt> [timeout=600]
# parent → sidecar 로 큰 입력 전달. local-path 를 spool 에 복사하고
# size+sha256 을 함께 알려준 뒤, sidecar 의 통상 텍스트 답변 (cmux_ask) 반환.
# 사용자 답변도 대용량이면 별도로 cmux_ask_file 을 호출하라.
cmux_send_file() {
  local surface="$1" local_path="$2" prompt="$3" timeout="${4:-600}"

  _cmux_spool_init || { echo "[cmux] spool init failed: $CMUX_SPOOL_DIR" >&2; return 1; }
  [ -f "$local_path" ] || { echo "[cmux] file not found: $local_path" >&2; return 1; }

  local job infile size sha
  job="$(cmux_job)"
  infile="$CMUX_SPOOL_DIR/$job.in"

  cp "$local_path" "$infile.tmp" || return 1
  mv "$infile.tmp" "$infile"
  size="$(_cmux_size "$infile")"
  sha="$(_cmux_sha256 "$infile")"

  local enriched="$prompt

[cmux:file 입력] 입력 본문은 아래 파일에 있습니다. 직접 읽어서 처리하세요:
  CMUX_INPUT_FILE: $infile
  CMUX_INPUT_SIZE: $size
  CMUX_INPUT_SHA256: $sha"

  cmux_ask "$surface" "$enriched" "$timeout"
}

# cmux_cleanup_spool [job]
# 인자 없으면 24h 이상 묵은 spool 정리. 인자 있으면 그 job 의 in/out 정리.
cmux_cleanup_spool() {
  _cmux_spool_init || return 0
  if [ -n "$1" ]; then
    rm -f "$CMUX_SPOOL_DIR/$1".* 2>/dev/null
  else
    find "$CMUX_SPOOL_DIR" -type f -mmin +$(( 24 * 60 )) -delete 2>/dev/null
  fi
}

# ─────────────────────────────────────────────────────────────

# cmux_other_surfaces — self 가 속한 워크스페이스 내, self 를 뺀 surface ref 목록.
cmux_other_surfaces() {
  local tree
  tree="$(cmux tree 2>/dev/null)" || return 1

  local self_ws
  self_ws=$(echo "$tree" | awk '
    /workspace workspace:[0-9]+/ {
      match($0, /workspace:[0-9]+/)
      ws = substr($0, RSTART, RLENGTH)
    }
    /◀ here/ { print ws; exit }
  ')

  [ -z "$self_ws" ] && return 1

  echo "$tree" | awk -v target="$self_ws" '
    /workspace workspace:[0-9]+/ {
      match($0, /workspace:[0-9]+/)
      in_target = (substr($0, RSTART, RLENGTH) == target) ? 1 : 0
      next
    }
    /surface surface:[0-9]+/ {
      if (!in_target) next
      if ($0 ~ /◀ here/) next
      match($0, /surface:[0-9]+/)
      print substr($0, RSTART, RLENGTH)
    }
  '
}
