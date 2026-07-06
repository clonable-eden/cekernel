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
