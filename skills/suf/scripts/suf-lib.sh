#!/usr/bin/env bash
# suf-lib.sh — surface ↔ surface 통신 헬퍼
# source 해서 사용:  source ~/.agents/skills/suf/scripts/suf-lib.sh
#
# v3 — polling 정밀화. pipe-pane 은 TUI (Claude UI 등) 의 cursor-rewrite 를
# 못 캡처해서 false negative 가 잦았다. read-screen 으로 surface buffer 전체를
# 보되, "END 마커 횟수" 가 아니라 "닫힌 ANSWER..END pair 1개 이상" 으로 판정.
# send echo 위치 의존성 제거 — TUI/일반 shell 어디서나 동작.

suf_job() {
  local rnd
  rnd=$(od -vAn -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  echo "$(date +%s%N)-$$-${rnd:-0}"
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

# 내부 헬퍼 — surface buffer 에서 닫힌 ANSWER..END pair 가 ≥ 2 개일 때
# (1개는 sidecar 가 본 prompt echo, 추가가 진짜 답변) 마지막 pair 의 본문을
# stdout 으로 출력하고 exit 0. 부족하면 빈 출력 + exit 1.
_suf_try_extract() {
  local surface="$1" job="$2" lines="${3:-8000}"
  cmux read-screen --surface "$surface" --scrollback --lines "$lines" 2>/dev/null \
    | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
    | awk -v s="<<<SUF_ANSWER:$job>>>" -v e="<<<SUF_END:$job>>>" '
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

# suf_ask <surface> <prompt> [timeout=600]
# 송신 후 surface buffer 에 닫힌 ANSWER..END pair 가 등장할 때까지 폴링.
# 본문을 stdout 으로 출력, 실패 시 비어있고 exit 1.
suf_ask() {
  local surface="$1" prompt="$2" timeout="${3:-600}"
  local poll="${SUF_POLL_INTERVAL:-0.5}"
  local lines="${SUF_READ_LINES:-8000}"

  local job
  job="$(suf_say "$surface" "$prompt")" || return 1

  local deadline
  deadline=$(( $(date +%s) + timeout ))
  local body
  while (( $(date +%s) < deadline )); do
    body="$(_suf_try_extract "$surface" "$job" "$lines")" && {
      # 안정화 — sidecar 가 마커 닫고 추가 출력 중일 수 있음
      sleep "${SUF_GRACE:-0.5}"
      _suf_try_extract "$surface" "$job" "$lines"
      return 0
    }
    sleep "$poll"
  done
  echo "[suf] timeout: job=$job surface=$surface" >&2
  return 1
}

# ── 레거시 호환 (분리 호출) ───────────────────────────
# 새 코드는 suf_ask 만 쓰면 됨.

# suf_wait <surface> <job> [timeout=600]
# 닫힌 pair 1개 등장까지 폴링. exit 0 / 1.
suf_wait() {
  local surface="$1" job="$2" timeout="${3:-600}"
  local poll="${SUF_POLL_INTERVAL:-0.5}"
  local lines="${SUF_READ_LINES:-8000}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    _suf_try_extract "$surface" "$job" "$lines" >/dev/null && return 0
    sleep "$poll"
  done
  return 1
}

# suf_hear <surface> <job> [lines=8000]
# 마지막 ANSWER..END 블록 추출 (대기 없음).
suf_hear() {
  local surface="$1" job="$2" lines="${3:-8000}"
  _suf_try_extract "$surface" "$job" "$lines"
}

# suf_other_surfaces — self 가 속한 워크스페이스 내, self 를 뺀 surface ref 목록.
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
