#!/usr/bin/env bats
# session-id.bats — bats-core tests for scripts/shared/session-id.sh
#
# First .bats file of the ADR-0017 migration (step 1: harness bootstrap).
# Runs in the bats lane of run-tests.sh alongside the legacy harness.

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SESSION_SCRIPT="${CEKERNEL_DIR}/scripts/shared/session-id.sh"
}

@test "session-id.sh generates CEKERNEL_SESSION_ID when unset" {
  run bash -c "unset CEKERNEL_SESSION_ID CEKERNEL_IPC_DIR; source '${SESSION_SCRIPT}'; echo \"\${CEKERNEL_SESSION_ID}\""
  assert_eq "source exits 0" "0" "$status"
  assert_match "matches {name}-{hex8}" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$output"
}

@test "session-id.sh preserves an existing CEKERNEL_SESSION_ID" {
  run bash -c "export CEKERNEL_SESSION_ID='my-custom-session-abc12345'; unset CEKERNEL_IPC_DIR; source '${SESSION_SCRIPT}'; echo \"\${CEKERNEL_SESSION_ID}\""
  assert_eq "existing ID preserved" "my-custom-session-abc12345" "$output"
}

@test "session-id.sh derives CEKERNEL_IPC_DIR from the session ID" {
  local expected_var_dir="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
  run bash -c "export CEKERNEL_SESSION_ID='test-session-aabbccdd'; unset CEKERNEL_IPC_DIR; source '${SESSION_SCRIPT}'; echo \"\${CEKERNEL_IPC_DIR}\""
  assert_eq "IPC dir derived" "${expected_var_dir}/ipc/test-session-aabbccdd" "$output"
}

# Step D (orchestrator-launch.md): unset before source forces new session scope
# See: #622 — Orchestrator launch must be a new-session boundary

@test "Step D pattern: unset + source generates new ID even when CEKERNEL_SESSION_ID is already set" {
  local old_id="cekernel-deadbeef"
  run bash -c "
    export CEKERNEL_SESSION_ID='${old_id}'
    unset CEKERNEL_SESSION_ID
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_SESSION_ID}\"
  "
  assert_eq "exits 0" "0" "$status"
  assert_match "new ID has {name}-{hex8} format" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$output"
  # Must differ from the old ID
  if [[ "$output" == "$old_id" ]]; then
    echo "FAIL: Step D reused old session ID: ${output}" >&2
    return 1
  fi
}

@test "Step D pattern: unset + source generates new ID from clean environment" {
  run bash -c "
    unset CEKERNEL_SESSION_ID
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_SESSION_ID}\"
  "
  assert_eq "exits 0" "0" "$status"
  assert_match "new ID has {name}-{hex8} format" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$output"
}
