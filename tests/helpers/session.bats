#!/usr/bin/env bats
# session.bats — contract self-tests for tests/helpers/session.bash
#
# ADR-0017 follow-up: per-test unique CEKERNEL_SESSION_ID (derived from
# BATS_TEST_NAME) so parallel bats runs cannot collide on IPC directories.

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "set_test_session_id exports a well-formed CEKERNEL_SESSION_ID" {
  set_test_session_id
  assert_match "format {name}-{hex8}" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$CEKERNEL_SESSION_ID"
}

@test "test_session_id derives distinct IDs for distinct test names" {
  local id1 id2
  id1=$(BATS_TEST_NAME="alpha" test_session_id)
  id2=$(BATS_TEST_NAME="beta" test_session_id)
  [[ "$id1" != "$id2" ]] || {
    echo "FAIL: IDs should differ, both were: $id1" >&2
    return 1
  }
}

@test "test_session_id is deterministic for the same test name" {
  local id1 id2
  id1=$(BATS_TEST_NAME="alpha" test_session_id)
  id2=$(BATS_TEST_NAME="alpha" test_session_id)
  assert_eq "same name yields same ID" "$id1" "$id2"
}

@test "set_test_session_id composes with session-id.sh for a per-test IPC dir" {
  # Must override any CEKERNEL_IPC_DIR inherited from the environment
  # (e.g. a Worker's .cekernel-env), otherwise tests share IPC state.
  export CEKERNEL_IPC_DIR="/tmp/inherited-ipc-dir"
  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  assert_match "IPC dir ends with session ID" "/${CEKERNEL_SESSION_ID}$" "$CEKERNEL_IPC_DIR"
}
