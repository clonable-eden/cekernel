#!/usr/bin/env bats
# mock-claude.bats — contract self-tests for tests/helpers/mock-claude.bash
#
# ADR-0017 Decision 2: the canonical claude shim emulates the delegated-spawn
# contract (ADR-0016, observed on claude v2.1.201). These tests verify every
# behavior consumers rely on:
#   - `--bg` prints `backgrounded · <short-id>` and records argv
#   - `agents --json` emits full records (sessionId/kind/cwd/startedAt/state)
#     as a scriptable, per-call-consumed sequence that repeats its last
#     response (non-terminating sequences for poll-timeout branches)
#   - `stop <id>` records the call

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

setup() {
  mock_claude
}

# ── --bg spawn line + argv recording ──

@test "--bg prints 'backgrounded · <short-id>' with the enqueued short ID" {
  mock_claude_enqueue_short_id cafe0001
  run claude --bg --agent cekernel:worker "do the thing"
  assert_eq "exit status" "0" "$status"
  assert_eq "spawn line" "backgrounded · cafe0001" "$output"
}

@test "--bg consumes enqueued short IDs in order across calls" {
  mock_claude_enqueue_short_id aaaa1111
  mock_claude_enqueue_short_id bbbb2222
  run claude --bg "first"
  assert_eq "first spawn" "backgrounded · aaaa1111" "$output"
  run claude --bg "second"
  assert_eq "second spawn" "backgrounded · bbbb2222" "$output"
}

@test "--bg falls back to a default 8-hex short ID when the queue is empty" {
  run claude --bg "prompt"
  assert_match "default spawn line" "^backgrounded · [0-9a-f]{8}$" "$output"
}

@test "--bg records argv (one line per call)" {
  mock_claude_enqueue_short_id cafe0001
  claude --bg --agent cekernel:worker "prompt text" >/dev/null
  claude --bg --agent cekernel:reviewer "other" >/dev/null
  run cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log"
  assert_eq "first call argv" "--bg --agent cekernel:worker prompt text" "${lines[0]}"
  assert_eq "second call argv" "--bg --agent cekernel:reviewer other" "${lines[1]}"
}

@test "--bg is detected anywhere in argv, not only as the first flag" {
  mock_claude_enqueue_short_id cafe0001
  run claude --agent cekernel:worker --bg "prompt"
  assert_eq "spawn line" "backgrounded · cafe0001" "$output"
}

# ── agents --json full records ──

@test "agents --json emits full records: sessionId, kind, cwd, startedAt, state" {
  local rec
  rec=$(mock_claude_agent_record \
    "cafe0001-0000-4000-8000-000000000001" background \
    "/tmp/repo/.worktrees/issue/42-x" "2026-07-07T00:00:00Z" busy)
  mock_claude_enqueue_agents "[${rec}]"
  run claude agents --json
  assert_eq "exit status" "0" "$status"
  assert_match "sessionId" '"sessionId":"cafe0001-0000-4000-8000-000000000001"' "$output"
  assert_match "kind" '"kind":"background"' "$output"
  assert_match "cwd" '"cwd":"/tmp/repo/.worktrees/issue/42-x"' "$output"
  assert_match "startedAt" '"startedAt":"2026-07-07T00:00:00Z"' "$output"
  # Live sessions carry the status/state field split (#581)
  assert_match "status" '"status":"busy"' "$output"
  assert_match "state" '"state":"working"' "$output"
}

@test "agent records split live status/state; terminal records carry state only" {
  # Observed shape (verified 2026-07-07, #581): live → status:busy|blocked
  # + state:"working"; terminal → state:done|stopped, no status field.
  run mock_claude_agent_record \
    "cafe0001-0000-4000-8000-000000000001" background /tmp/wt 1700000000000 blocked
  assert_match "live status" '"status":"blocked"' "$output"
  assert_match "live state is working" '"state":"working"' "$output"

  run mock_claude_agent_record \
    "cafe0001-0000-4000-8000-000000000001" background /tmp/wt 1700000000000 stopped
  assert_match "terminal state" '"state":"stopped"' "$output"
  if [[ "$output" == *'"status"'* ]]; then
    echo "terminal record must not carry a status field: $output" >&2
    return 1
  fi
}

@test "agents --json emits [] when nothing is enqueued" {
  run claude agents --json
  assert_eq "empty roster" "[]" "$output"
}

@test "short-ID prefix capture path: --bg short ID prefixes a sessionId in agents --json" {
  # Normative capture path 1 (ADR-0016): extract the short ID from the spawn
  # line, prefix-match it against sessionId in agents --json.
  mock_claude_enqueue_short_id cafe0001
  local rec
  rec=$(mock_claude_agent_record \
    "cafe0001-0000-4000-8000-000000000001" background "/tmp/wt" \
    "2026-07-07T00:00:00Z" busy)
  mock_claude_enqueue_agents "[${rec}]"
  local short_id
  short_id="$(claude --bg "prompt" | sed 's/^backgrounded · //')"
  run claude agents --json
  assert_match "prefix match" "\"sessionId\":\"${short_id}" "$output"
}

@test "agents --json can script the kind+cwd+startedAt fallback with an interactive session at repo root" {
  # Normative capture path 2 (ADR-0016 fallback) and the interactive-session
  # mis-match regression: the roster must be able to contain an interactive
  # session sharing the repo-root cwd alongside the background worker.
  local interactive background
  interactive=$(mock_claude_agent_record \
    "11111111-0000-4000-8000-000000000001" interactive "/tmp/repo" \
    "2026-07-07T00:00:00Z" busy)
  background=$(mock_claude_agent_record \
    "22222222-0000-4000-8000-000000000002" background "/tmp/repo" \
    "2026-07-07T00:01:00Z" busy)
  mock_claude_enqueue_agents "[${interactive},${background}]"
  run claude agents --json
  assert_match "interactive record present" '"kind":"interactive"' "$output"
  assert_match "background record present" '"kind":"background"' "$output"
  assert_match "distinct startedAt for fallback" '"startedAt":"2026-07-07T00:01:00Z"' "$output"
}

# ── scriptable state sequences ──

@test "agents --json replays the enqueued sequence one response per call" {
  local rec_busy rec_done
  rec_busy=$(mock_claude_agent_record \
    "cafe0001-0000-4000-8000-000000000001" background "/tmp/wt" \
    "2026-07-07T00:00:00Z" busy)
  rec_done=$(mock_claude_agent_record \
    "cafe0001-0000-4000-8000-000000000001" background "/tmp/wt" \
    "2026-07-07T00:00:00Z" done)
  mock_claude_enqueue_agents "[${rec_busy}]"
  mock_claude_enqueue_agents "[${rec_done}]"
  run claude agents --json
  assert_match "first call is busy" '"status":"busy"' "$output"
  run claude agents --json
  assert_match "second call is done" '"state":"done"' "$output"
}

@test "agents --json repeats the last response forever (non-terminating sequence)" {
  # Required so wrapper.sh's poll-timeout branch is testable (ADR-0017):
  # a sequence that never reaches a terminal state.
  local rec
  rec=$(mock_claude_agent_record \
    "cafe0001-0000-4000-8000-000000000001" background "/tmp/wt" \
    "2026-07-07T00:00:00Z" busy)
  mock_claude_enqueue_agents "[${rec}]"
  local i
  for i in 1 2 3; do
    run claude agents --json
    assert_match "call ${i} stays busy" '"status":"busy"' "$output"
  done
}

# ── stop recording ──

@test "stop <id> records the call" {
  claude stop cafe0001
  claude stop beef0002
  run cat "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "first stop" "cafe0001" "${lines[0]}"
  assert_eq "second stop" "beef0002" "${lines[1]}"
}

# ── error paths ──

@test "unsupported invocations fail noisily" {
  # Rule of Repair: an argv shape the mock does not model must not be
  # silently accepted.
  run claude logs cafe0001
  assert_eq "exit status" "1" "$status"
  assert_match "diagnostic on stderr" "unsupported" "$output"
}
