#!/usr/bin/env bash
# suf-lib.sh — surface ↔ surface 통신 헬퍼
# source 해서 사용:  source ~/.agents/skills/suf/scripts/suf-lib.sh

suf_job() {
  echo "$(date +%s%N)-$$"
}

# suf_say <surface> <prompt>
# 마커/ack 지시를 자동 부착해 송신. JOB 토큰을 stdout 으로 echo.
suf_say() {
  local surface="$1" prompt="$2"
  local job
  job="$(suf_job)"

  local full="$prompt

답변은 반드시 아래 두 마커 사이에 작성하세요 (다른 곳에 본문을 두지 마세요):
<<<SUF_ANSWER:$job>>>
(여기에 답변 본문)
<<<SUF_END:$job>>>"

  cmux send --surface "$surface" -- "$full" >/dev/null
  cmux send-key --surface "$surface" Enter >/dev/null
  echo "$job"
}

# suf_wait <surface> <job> [timeout=600]
# scrollback 의 END 마커 등장 횟수를 폴링.
# cmux send 가 prompt 를 surface 에 echo 하므로 baseline 1회 + sidecar 응답 1회 = >= 2 가 완료 신호.
suf_wait() {
  local surface="$1" job="$2" timeout="${3:-600}"
  local end_marker="<<<SUF_END:$job>>>"
  local interval="${SUF_POLL_INTERVAL:-1}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local count
    count=$(cmux read-screen --surface "$surface" --scrollback --lines 4000 2>/dev/null \
      | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
      | grep -cF "$end_marker")
    if (( count >= 2 )); then
      return 0
    fi
    sleep "$interval"
  done
  return 1
}

# suf_hear <surface> <job> [lines=4000]
# scrollback 에서 마지막 ANSWER..END 블록만 추출 (prompt echo 블록 제외), ANSI 제거.
suf_hear() {
  local surface="$1" job="$2" lines="${3:-4000}"
  cmux read-screen --surface "$surface" --scrollback --lines "$lines" \
    | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
    | awk -v s="<<<SUF_ANSWER:$job>>>" -v e="<<<SUF_END:$job>>>" '
        index($0,s) { flag=1; buf=""; next }
        index($0,e) { if (flag) { last=buf } flag=0; next }
        flag { buf = buf $0 "\n" }
        END { printf "%s", last }
      '
}

# suf_ask <surface> <prompt> [timeout=600]
# 한 사이클 (say + wait + hear) 을 함께. 성공 시 본문을 stdout, 실패 시 비어있고 exit 1.
suf_ask() {
  local surface="$1" prompt="$2" timeout="${3:-600}"
  local job
  job="$(suf_say "$surface" "$prompt")" || return 1
  suf_wait "$surface" "$job" "$timeout" >/dev/null || {
    echo "[suf] timeout: job=$job surface=$surface" >&2
    return 1
  }
  sleep "${SUF_GRACE:-0.5}"
  suf_hear "$surface" "$job"
}

# suf_other_surfaces
# self 가 속한 워크스페이스 내에서, self 를 뺀 surface ref 목록.
# - 다른 워크스페이스의 surface 는 제외 (분리된 작업 컨텍스트)
# - self 는 cmux tree 의 "◀ here" 마커로 판별
suf_other_surfaces() {
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
