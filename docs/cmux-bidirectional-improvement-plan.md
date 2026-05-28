# cmux Bidirectional Communication Improvement Plan

## Diagnosis

The current cmux v5 implementation is not a bidirectional communication layer. It is a one-shot RPC wrapper around a terminal surface:

1. The parent injects a prompt into a sidecar PTY using `cmux send`.
2. The parent presses Enter separately using `cmux send-key`.
3. The sidecar is instructed, through prompt text, to write its answer to a per-job FIFO.
4. The parent blocks on that FIFO, then optionally falls back to screen-marker scraping.

That design can work for short parent-initiated requests, but it breaks down for true agent-to-agent coordination.

## Main Problems

### 1. `cmux_send` is transport injection, not messaging

`cmux_send` currently writes a full prompt to a surface and then sends Enter as a second RPC. This has several failure modes:

- `cmux send` and `cmux send-key Enter` can race.
- Double Enter is used as insurance, which can create accidental empty submissions.
- There is no daemon-level acknowledgement that the prompt was accepted by the receiving agent.
- There is no structured message ID, sender, recipient, state, or reply routing visible to the receiver except what is embedded in the prompt.

The user-mentioned `cumx_send` appears to be a typo or caller-side name drift. The repo exposes `cmux_send`, not `cumx_send`. Add an explicit alias/error guard only if this typo is recurring in real usage.

### 2. FIFO response is one-way

The per-job FIFO is created by the parent and written by the sidecar. That supports:

- parent asks
- sidecar answers
- parent collects

It does not support:

- sidecar asks a clarification back
- sidecar emits progress events independently
- sidecar requests data from parent without starting another nested PTY injection
- either side resumes a conversation after a timeout

So the current design is request/response, not bidirectional dialogue.

### 3. Token overhead is built into every LLM-mode call

Each LLM-mode call appends a large instruction block explaining FIFO, heredoc, fallback markers, quote handling, and output rules. When fallback is enabled, it also embeds screen-marker instructions.

This cost repeats on every request. It also tells the receiving model to use the caveman skill, which can trigger more prompt/context loading. For short requests, protocol boilerplate can easily be larger than the useful prompt.

### 4. Screen fallback reintroduces the old noise path

The script comments say v5 removed `read-screen` polling, but `_cmux_v5_read_fifo_dynamic` still polls `cmux read-screen --lines 30` for LLM idle detection, and fallback mode extracts marker-delimited chat output.

That means token/noise reduction only holds on the happy FIFO path. When the sidecar cannot write the FIFO, the system falls back to screen scraping and chat-visible protocol text.

### 5. Async jobs lack a durable mailbox

`cmux_send` creates a FIFO and returns a job id. `cmux_collect` later discovers pending FIFO files. This is enough for pending result collection, but not enough for coordination:

- no append-only message log
- no inbox per surface
- no outbox per surface
- no `ack`, `progress`, `need-input`, `result`, `error`, `cancelled` states
- no replay after parent process exits
- no way to route a sidecar-originated message back to the parent without inventing another ad hoc prompt

## Proposed Direction

Replace the current prompt-encoded protocol with a small local message bus, while keeping PTY injection only as a compatibility wake-up mechanism.

### Phase 1: Introduce envelopes and a spool directory

Create a durable spool under something like:

```text
/tmp/cmux-bus/
  surfaces/
    surface-9/
      inbox/
      outbox/
      state.json
  jobs/
    <job_id>.json
    <job_id>.in
    <job_id>.out
    <job_id>.events.jsonl
```

Every message should be a compact JSON envelope:

```json
{
  "id": "job_...",
  "parent_id": null,
  "from": "surface:1",
  "to": "surface:9",
  "type": "request",
  "reply_to": "/tmp/cmux-bus/jobs/job_....out",
  "events": "/tmp/cmux-bus/jobs/job_....events.jsonl",
  "body_ref": "/tmp/cmux-bus/jobs/job_....in",
  "response_max": 4096,
  "deadline_ms": 30000
}
```

The prompt sent through `cmux send` should shrink to a tiny wake-up instruction:

```text
cmux job: /tmp/cmux-bus/jobs/job_....json
Read it, write events/result to the listed paths. No chat output unless blocked.
```

That removes most repeated protocol tokens.

### Phase 2: Add true bidirectional APIs

Add APIs that model messages rather than terminal injection:

- `cmux_request <surface> <body>`: parent sends request and waits for final result.
- `cmux_post <surface> <body>`: enqueue request and return job id.
- `cmux_recv [--surface self]`: receive the next inbound message for this surface.
- `cmux_reply <job> <body>`: write a final response.
- `cmux_event <job> <type> <body>`: append progress, ack, need-input, warning, error.
- `cmux_ask_parent <job> <question>`: sidecar asks the original sender for clarification.
- `cmux_wait <job>`: wait for final result or terminal state.

This makes sidecar-to-parent communication first-class instead of forcing nested `cmux_send` calls.

### Phase 3: Add a tiny receiver shim for agents

For LLM sidecars, do not resend the full FIFO/heredoc tutorial on every task. Install or document a tiny receiver shim once per session:

```bash
source ~/.agents/skills/cmux/scripts/cmux-agent.sh
cmux_agent_loop surface:9
```

Then the parent only wakes the sidecar with a short job path. The receiver shim reads the envelope, writes status/events/results, and handles quoting safely in shell code instead of in model instructions.

For shells/workers, the same shim can process jobs without involving an LLM at all.

### Phase 4: Make fallback explicit and expensive

Fallback to screen markers should not be default. Recommended defaults:

- FIFO/spool path: default.
- Screen marker fallback: opt-in with `CMUX_ALLOW_SCREEN_FALLBACK=1`.
- If fallback is used, return a warning event so callers can measure it.

This keeps token/noise costs visible instead of silently paying them.

### Phase 5: Fix `cmux_send` semantics

Keep `cmux_send` as a compatibility wrapper, but change its meaning:

- It should create an envelope and enqueue/wake the receiver.
- It should not directly encode the full protocol into the prompt.
- It should return a job id plus path when requested: `--json`.
- It should use one atomic terminal submission if cmux supports it, or the daemon should expose `send-submit` to combine send + Enter.
- Add a `cumx_send` compatibility function that fails fast with: `did you mean cmux_send?`

## Recommended API Shape

Short request:

```bash
answer=$(cmux_request surface:9 "branch? one line" --timeout 20)
```

Async task:

```bash
job=$(cmux_post surface:9 "run focused tests and report failures")
cmux_events "$job" --follow
cmux_wait "$job" --timeout 600
```

Sidecar clarification:

```bash
cmux_event "$job" need-input "Which test target?"
answer=$(cmux_recv --reply-to "$job" --timeout 300)
```

Compatibility:

```bash
cmux_send surface:9 "old API request"
cmux_collect "$job"
```

## Implementation Order

1. Add a small JSON envelope/spool implementation beside `cmux-v5-lib.sh`.
2. Implement `cmux_post`, `cmux_wait`, `cmux_event`, and `cmux_reply` on top of files/FIFOs.
3. Make `cmux_send` call `cmux_post` internally.
4. Add a receiver shim and reduce LLM prompt injection to a one-line job-path wake-up.
5. Gate screen fallback behind an env flag.
6. Add shell-level tests for job lifecycle, timeout, cancellation, progress events, and typo handling.

## Expected Impact

- Much lower token use: repeated FIFO/heredoc instructions are replaced by a short job-path wake-up.
- Real bidirectional flow: sidecar can emit events and ask questions through the same bus.
- Better reliability: message state survives parent process exit and can be inspected.
- Easier debugging: every job has an envelope, event log, input body, and output body.
- Backward compatibility: existing `cmux_ask`, `cmux_send`, and `cmux_collect` can remain as wrappers.
