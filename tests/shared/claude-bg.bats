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
