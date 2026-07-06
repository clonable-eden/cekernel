#!/usr/bin/env bats
# claude-session-id.bats — tests for scripts/shared/claude-session-id.sh
#
# Persist/read of the Orchestrator's Claude Code session ID. The ID is
# captured at spawn time by spawn-orchestrator.sh (ADR-0016 Phase 2);
# the discovery heuristic was removed (#571), so only persist/read remain.

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"

  source "${CEKERNEL_DIR}/scripts/shared/claude-session-id.sh"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "persist writes the session ID to orchestrator.claude-session-id" {
  claude_session_id_persist "abcd1234-5678-90ab-cdef-1234567890ab"
  assert_file_exists "session ID file created" \
    "${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id"
  assert_eq "persisted content" "abcd1234-5678-90ab-cdef-1234567890ab" \
    "$(cat "${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id")"
}

@test "persist fails without CEKERNEL_IPC_DIR" {
  run bash -c "
    source '${CEKERNEL_DIR}/scripts/shared/claude-session-id.sh'
    unset CEKERNEL_IPC_DIR
    claude_session_id_persist test
  "
  assert_eq "exit status" "1" "$status"
}

@test "persist overwrites an existing value" {
  claude_session_id_persist "first-value"
  claude_session_id_persist "second-value"
  run claude_session_id_read
  assert_eq "overwritten value" "second-value" "$output"
}

@test "read returns the persisted session ID" {
  claude_session_id_persist "abcd1234-5678-90ab-cdef-1234567890ab"
  run claude_session_id_read
  assert_eq "exit status" "0" "$status"
  assert_eq "read value" "abcd1234-5678-90ab-cdef-1234567890ab" "$output"
}

@test "read fails when the file does not exist" {
  run claude_session_id_read
  assert_eq "exit status" "1" "$status"
}

@test "read fails without CEKERNEL_IPC_DIR" {
  run bash -c "
    source '${CEKERNEL_DIR}/scripts/shared/claude-session-id.sh'
    unset CEKERNEL_IPC_DIR
    claude_session_id_read
  "
  assert_eq "exit status" "1" "$status"
}
