#!/usr/bin/env bats
# health-check.bats — v2 contract tests for scripts/orchestrator/health-check.sh
#
# Under --bg delegation (ADR-0016 Phase 1) health-check.sh maps headless
# liveness to `claude agents --json` state and MUST surface `blocked`
# (permission-dialog stall) as a distinct status.

load '../helpers/assertions'
load '../helpers/session'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

TOKEN="aaaa1111-2222-4333-8444-555566667777"

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  HEALTH_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"

  mock_claude
  export CEKERNEL_BACKEND=headless
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

# Active worker fixture: handle + RUNNING state
_active_worker() {
  local issue="$1"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-${issue}.worker"
  worker_state_write "$issue" RUNNING "phase1:implement"
}

@test "health-check reports healthy for a busy session" {
  _active_worker 90
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"

  run bash "$HEALTH_SCRIPT" 90
  assert_eq "exit 0 (healthy)" "0" "$status"
  assert_match "status healthy" '"status":"healthy"' "$output"
}

@test "health-check surfaces a blocked session as a distinct status" {
  _active_worker 91
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 blocked)]"

  run bash "$HEALTH_SCRIPT" 91
  assert_eq "exit 1 (unhealthy)" "1" "$status"
  assert_match "status blocked" '"status":"blocked"' "$output"
}

@test "health-check reports zombie when the session is no longer listed" {
  _active_worker 92
  # empty agents queue → [] → session missing

  run bash "$HEALTH_SCRIPT" 92
  assert_eq "exit 1 (zombie)" "1" "$status"
  assert_match "status zombie" '"status":"zombie"' "$output"
}

@test "health-check does not zombie-flag on a failing agents query (ADR-0018)" {
  # Degradation policy: query-failed is inconclusive, not evidence of a
  # crash — report "unknown" without counting the worker unhealthy.
  _active_worker 93
  mock_bin claude 'exit 1'

  run bash "$HEALTH_SCRIPT" 93
  assert_eq "exit 0 (inconclusive is not unhealthy)" "0" "$status"
  assert_match "status unknown" '"status":"unknown"' "$output"
}

@test "health-check does not zombie-flag on an unknown (status, state) pair (ADR-0018)" {
  _active_worker 94
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$TOKEN" background /tmp/wt 1700000000000 running active)]"

  run bash "$HEALTH_SCRIPT" 94
  assert_eq "exit 0 (inconclusive is not unhealthy)" "0" "$status"
  assert_match "status unknown" '"status":"unknown"' "$output"
}

# ── ADR-0020 Phase 2: state-based zombie detection ──

@test "health-check discovers workers by state file (ADR-0020 Phase 2)" {
  _active_worker 95
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"

  run bash "$HEALTH_SCRIPT"
  assert_match "worker found by state file" '"issue":95' "$output"
  assert_match "status healthy" '"status":"healthy"' "$output"
}

@test "health-check zombie = non-TERMINATED + dead verdict (ADR-0020 Phase 2)" {
  # Worker with non-TERMINATED state + dead backend → zombie
  _active_worker 96

  run bash "$HEALTH_SCRIPT"
  assert_eq "exit 1 (zombie)" "1" "$status"
  assert_match "status zombie" '"status":"zombie"' "$output"
}

@test "health-check skips TERMINATED workers (ADR-0020 Phase 2)" {
  worker_state_write 97 TERMINATED "ci-passed:55"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-97.worker"

  run bash "$HEALTH_SCRIPT"
  # TERMINATED workers should not be inspected at all
  if [[ "$output" == *'"issue":97'* ]]; then
    echo "FAIL: TERMINATED worker should not be inspected" >&2
    return 1
  fi
}
