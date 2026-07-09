#!/usr/bin/env bats
# check-signal.bats — bats-core tests for scripts/process/check-signal.sh
#
# Verifies signal detection, consumption, and log recording behavior.

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CHECK_SIGNAL="${CEKERNEL_DIR}/scripts/process/check-signal.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "no signal file exits 1" {
  run bash "$CHECK_SIGNAL" 42
  assert_eq "exit 1" "1" "$status"
}

@test "TERM signal detected exits 0 and outputs signal name" {
  echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-42.signal"
  run bash "$CHECK_SIGNAL" 42
  assert_eq "exit 0" "0" "$status"
  assert_eq "output is TERM" "TERM" "$output"
}

@test "signal file is consumed after detection" {
  echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-42.signal"
  bash "$CHECK_SIGNAL" 42 >/dev/null
  assert_not_exists "signal file consumed" "${CEKERNEL_IPC_DIR}/worker-42.signal"
}

@test "SUSPEND signal detected exits 0 and outputs signal name" {
  echo "SUSPEND" > "${CEKERNEL_IPC_DIR}/worker-43.signal"
  run bash "$CHECK_SIGNAL" 43
  assert_eq "exit 0" "0" "$status"
  assert_eq "output is SUSPEND" "SUSPEND" "$output"
  assert_not_exists "signal file consumed" "${CEKERNEL_IPC_DIR}/worker-43.signal"
}

@test "missing issue number exits non-zero" {
  run bash "$CHECK_SIGNAL"
  assert_eq "exit 1" "1" "$status"
}

@test "trailing whitespace in signal file is trimmed" {
  printf "TERM\n" > "${CEKERNEL_IPC_DIR}/worker-55.signal"
  run bash "$CHECK_SIGNAL" 55
  assert_eq "output is TERM" "TERM" "$output"
  assert_not_exists "signal file consumed" "${CEKERNEL_IPC_DIR}/worker-55.signal"
}

@test "log entry recorded when signal is consumed" {
  echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-60.signal"
  bash "$CHECK_SIGNAL" 60 >/dev/null

  local log_file="${CEKERNEL_IPC_DIR}/logs/worker-60.log"
  assert_file_exists "log file created" "$log_file"
  local log_content
  log_content=$(cat "$log_file")
  assert_match "log contains SIGNAL_RECEIVED" "SIGNAL_RECEIVED" "$log_content"
  assert_match "log contains issue number" "issue=#60" "$log_content"
  assert_match "log contains signal name" "signal=TERM" "$log_content"
}
