#!/usr/bin/env bats
# phase-transition.bats — bats-core tests for scripts/process/phase-transition.sh
#
# Verifies atomic signal-check + state-write behavior at phase boundaries.

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PHASE_TRANSITION="${CEKERNEL_DIR}/scripts/process/phase-transition.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "no signal writes state and exits 0" {
  run bash "$PHASE_TRANSITION" 100 RUNNING "phase1:implement"
  assert_eq "exit 0" "0" "$status"

  local state_file="${CEKERNEL_IPC_DIR}/worker-100.state"
  assert_file_exists "state file created" "$state_file"
  local content
  content=$(cat "$state_file")
  assert_match "state contains RUNNING" "^RUNNING:" "$content"
  assert_match "state contains detail" "phase1:implement" "$content"
}

@test "TERM signal outputs signal and exits 3 without writing state" {
  echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-101.signal"
  run bash "$PHASE_TRANSITION" 101 RUNNING "phase1:implement"
  assert_eq "exit 3" "3" "$status"
  assert_eq "output is TERM" "TERM" "$output"
  assert_not_exists "signal file consumed" "${CEKERNEL_IPC_DIR}/worker-101.signal"
  assert_not_exists "state file not created" "${CEKERNEL_IPC_DIR}/worker-101.state"
}

@test "SUSPEND signal outputs signal and exits 3" {
  echo "SUSPEND" > "${CEKERNEL_IPC_DIR}/worker-102.signal"
  run bash "$PHASE_TRANSITION" 102 WAITING "phase3:ci-waiting"
  assert_eq "exit 3" "3" "$status"
  assert_eq "output is SUSPEND" "SUSPEND" "$output"
  assert_not_exists "signal file consumed" "${CEKERNEL_IPC_DIR}/worker-102.signal"
}

@test "missing issue number exits non-zero" {
  run bash "$PHASE_TRANSITION"
  assert_eq "exit 1" "1" "$status"
}

@test "missing state exits non-zero" {
  run bash "$PHASE_TRANSITION" 200
  assert_eq "exit 1" "1" "$status"
}

@test "detail is optional" {
  run bash "$PHASE_TRANSITION" 103 RUNNING
  assert_eq "exit 0" "0" "$status"
  assert_file_exists "state file created" "${CEKERNEL_IPC_DIR}/worker-103.state"
}

@test "WAITING state works" {
  run bash "$PHASE_TRANSITION" 104 WAITING "phase3:ci-waiting"
  assert_eq "exit 0" "0" "$status"
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/worker-104.state")
  assert_match "state contains WAITING" "^WAITING:" "$content"
}

@test "TDD sub-detail with parentheses is preserved" {
  run bash "$PHASE_TRANSITION" 105 RUNNING "phase1:implement(red)"
  assert_eq "exit 0" "0" "$status"
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/worker-105.state")
  assert_match "TDD sub-detail preserved" 'phase1:implement\(red\)' "$content"
}
