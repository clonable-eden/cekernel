#!/usr/bin/env bats
# send-signal.bats — bats-core tests for scripts/orchestrator/send-signal.sh
#
# Behavior under test:
#   - TERM/SUSPEND signal creates the correct signal file
#   - Missing arguments exit non-zero
#   - Unsupported signals are rejected
#   - Signal file is overwritten on re-send
#   - Missing IPC directory exits non-zero

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SEND_SIGNAL="${CEKERNEL_DIR}/scripts/orchestrator/send-signal.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "TERM signal creates signal file with correct content" {
  run bash "$SEND_SIGNAL" 42 TERM
  assert_eq "send-signal exits 0" "0" "$status"

  local signal_file="${CEKERNEL_IPC_DIR}/worker-42.signal"
  assert_file_exists "signal file created" "$signal_file"
  assert_eq "signal file contains TERM" "TERM" "$(cat "$signal_file")"
}

@test "SUSPEND signal creates signal file with correct content" {
  run bash "$SEND_SIGNAL" 43 SUSPEND
  assert_eq "send-signal exits 0" "0" "$status"

  local signal_file="${CEKERNEL_IPC_DIR}/worker-43.signal"
  assert_file_exists "signal file created" "$signal_file"
  assert_eq "signal file contains SUSPEND" "SUSPEND" "$(cat "$signal_file")"
}

@test "missing issue number exits non-zero" {
  run bash "$SEND_SIGNAL"
  assert_eq "exits non-zero" "1" "$status"
}

@test "missing signal name exits non-zero" {
  run bash "$SEND_SIGNAL" 42
  assert_eq "exits non-zero" "1" "$status"
}

@test "unsupported signal HUP is rejected" {
  run bash "$SEND_SIGNAL" 42 HUP
  assert_eq "exits non-zero" "1" "$status"
  assert_not_exists "no signal file for rejected signal" "${CEKERNEL_IPC_DIR}/worker-42.signal"
}

@test "signal file overwrites existing signal" {
  echo "OLD" > "${CEKERNEL_IPC_DIR}/worker-50.signal"

  run bash "$SEND_SIGNAL" 50 TERM
  assert_eq "send-signal exits 0" "0" "$status"
  assert_eq "signal file overwritten" "TERM" "$(cat "${CEKERNEL_IPC_DIR}/worker-50.signal")"
}

@test "missing IPC directory exits non-zero" {
  rm -rf "$CEKERNEL_IPC_DIR"

  run bash "$SEND_SIGNAL" 42 TERM
  assert_eq "exits non-zero" "1" "$status"
}
