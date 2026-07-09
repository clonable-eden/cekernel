#!/usr/bin/env bats
# watch-logs.bats — bats-core tests for scripts/orchestrator/watch-logs.sh
#
# Behavior under test:
#   - Exits non-zero when log directory does not exist
#   - Exits non-zero when the specified issue has no log file

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WATCH_LOGS="${CEKERNEL_DIR}/scripts/orchestrator/watch-logs.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "exits non-zero when log directory does not exist" {
  # IPC dir (and thus logs/) intentionally not created
  run bash "$WATCH_LOGS"
  assert_eq "exits non-zero" "1" "$status"
}

@test "exits non-zero for nonexistent issue log file" {
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
  # No worker-999.log exists
  run bash "$WATCH_LOGS" 999
  assert_eq "exits non-zero" "1" "$status"
}
