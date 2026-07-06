#!/usr/bin/env bats
# claude-bg.bats — tests for scripts/shared/claude-bg.sh
#
# Shared `claude --bg` session helpers (ADR-0016): agents --json query,
# token → state resolution, aliveness, and the normative session-ID
# capture order. Consumers (headless.sh, spawn-orchestrator.sh, orchctl.sh)
# are covered by their own suites; this file pins the helper contract.

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

FULL_UUID="aaaa1111-2222-4333-8444-555566667777"

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  mock_claude
  source "${CEKERNEL_DIR}/scripts/shared/claude-bg.sh"
}

# ── claude_bg_state_for_token ──

@test "state_for_token echoes the state for a full-UUID token" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_state_for_token "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "state" "busy" "$output"
}

@test "state_for_token prefix-matches a short-ID token" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 blocked)]"
  run claude_bg_state_for_token "aaaa1111"
  assert_eq "exit status" "0" "$status"
  assert_eq "state" "blocked" "$output"
}

@test "state_for_token fails when no session matches" {
  # queue empty → []
  run claude_bg_state_for_token "$FULL_UUID"
  assert_eq "exit status" "1" "$status"
  assert_eq "no output" "" "$output"
}

# ── claude_bg_token_alive ──

@test "token_alive: busy and blocked are alive; done and missing are not" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "busy is alive" "0" "$status"

  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 blocked)]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "blocked is alive" "0" "$status"

  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "done is dead" "1" "$status"

  mock_claude_enqueue_agents "[]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "missing is dead" "1" "$status"
}

@test "token_alive: live record with status but no state field is alive" {
  # Observed live shape variant (#581): status:"busy" with NO state field.
  mock_claude_enqueue_agents \
    "[{\"sessionId\":\"$FULL_UUID\",\"kind\":\"background\",\"cwd\":\"/tmp/x\",\"startedAt\":1700000000000,\"status\":\"busy\"}]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "status-only busy is alive" "0" "$status"
}

@test "token_alive: legacy record shape (state:busy, no status) stays alive" {
  # Backward compat (#581): the pre-split shape put the live state in
  # `state` with no `status` field. The status-preferring query must
  # still fall back to `state`.
  mock_claude_enqueue_agents \
    "[{\"sessionId\":\"$FULL_UUID\",\"kind\":\"background\",\"cwd\":\"/tmp/x\",\"startedAt\":1700000000000,\"state\":\"busy\"}]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "legacy busy is alive" "0" "$status"
}

# ── claude_bg_token_alive_from_json ──

@test "token_alive_from_json: busy and blocked are alive; done and missing are not" {
  # Pre-fetched body — no CLI call. Single-fetch views (orchctl ps/count)
  # resolve every token against one response (ADR-0016 Phase 4); the
  # busy/blocked liveness vocabulary lives HERE, not in the view layers.
  local json
  json="[
    $(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy),
    $(mock_claude_agent_record "bbbb0000-1111-4222-8333-444455556666" background /tmp/x 1700000001000 blocked),
    $(mock_claude_agent_record "cccc0000-1111-4222-8333-444455556666" background /tmp/x 1700000002000 done)
  ]"

  run claude_bg_token_alive_from_json "$json" "$FULL_UUID"
  assert_eq "busy is alive" "0" "$status"

  run claude_bg_token_alive_from_json "$json" "bbbb0000"
  assert_eq "blocked is alive" "0" "$status"

  run claude_bg_token_alive_from_json "$json" "cccc0000"
  assert_eq "done is dead" "1" "$status"

  run claude_bg_token_alive_from_json "$json" "ffff0000"
  assert_eq "missing is dead" "1" "$status"
}

@test "token_alive_from_json: real live shape (status:busy + state:working) is alive" {
  # Real CLI live records carry the normative state in `status` while
  # `state` reads "working" (#581). The raw literal pins the shape
  # independently of the mock helper.
  local json
  json="[{\"sessionId\":\"$FULL_UUID\",\"kind\":\"background\",\"cwd\":\"/tmp/x\",\"startedAt\":1700000000000,\"status\":\"busy\",\"state\":\"working\"}]"
  run claude_bg_token_alive_from_json "$json" "$FULL_UUID"
  assert_eq "status busy + state working is alive" "0" "$status"
}

@test "token_alive_from_json: does not call the claude CLI" {
  local json
  json="[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_token_alive_from_json "$json" "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_not_exists "no agents --json call recorded" \
    "${MOCK_CLAUDE_STATE_DIR}/agents-calls"
}

# ── claude_bg_capture_session_id ──

@test "capture: short ID prefix-matches to the full UUID (primary path)" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_capture_session_id "aaaa1111" /tmp/x
  assert_eq "exit status" "0" "$status"
  assert_eq "full UUID" "$FULL_UUID" "$output"
}

@test "capture: empty short ID falls back to newest background session at cwd" {
  # An interactive session with a newer startedAt at the same cwd must NOT
  # match (kind filter is mandatory — #571), nor an older background one.
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "bbbb0000-1111-4222-8333-444455556666" interactive /tmp/x 1700000099000 busy),
    $(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy),
    $(mock_claude_agent_record "cccc0000-1111-4222-8333-444455556666" background /tmp/x 1699999999000 busy)
  ]"
  run claude_bg_capture_session_id "" /tmp/x
  assert_eq "exit status" "0" "$status"
  assert_eq "newest background at cwd" "$FULL_UUID" "$output"
}

@test "capture: fails when nothing resolves" {
  # queue empty → [] forever
  run claude_bg_capture_session_id "" /tmp/x
  assert_eq "exit status" "1" "$status"
}

# ── claude_bg_wait_terminal (ADR-0016 Phase 3) ──
# Polls to a terminal-for-unattended-supervision state. blocked is terminal
# here: an unattended (cron/at) session waiting on a permission dialog will
# never be approved, so waiting longer cannot help.

@test "wait_terminal: echoes done when the session completes" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "done" "$output"
}

@test "wait_terminal: blocked is terminal (unattended permission stall)" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 blocked)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "blocked" "$output"
}

@test "wait_terminal: stopped is terminal" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 stopped)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "stopped" "$output"
}

@test "wait_terminal: echoes timeout when the session never leaves busy" {
  # Non-terminating sequence: the last enqueued response repeats forever
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_wait_terminal "$FULL_UUID" 1 1
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "timeout" "$output"
}

@test "wait_terminal: transient missing session keeps polling to terminal" {
  # Daemon restart window: session temporarily absent, then reported done
  mock_claude_enqueue_agents "[]"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "done" "$output"
}

@test "wait_terminal: prefix-matches a short-ID token" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_wait_terminal "aaaa1111" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "done" "$output"
}
