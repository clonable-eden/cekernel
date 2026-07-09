#!/usr/bin/env bats
# worker-state.bats — bats-core tests for worker_state_list_active
# (ADR-0020 Phase 2: roster enumeration via state files)
#
# worker_state_list_active enumerates issue numbers from non-TERMINATED
# state files in a given IPC directory. Used by all roster consumers
# (orchctl ls, process-status.sh, health-check.sh).

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "worker_state_list_active: empty dir returns nothing" {
  run worker_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  assert_eq "empty output" "" "$output"
}

@test "worker_state_list_active: lists RUNNING worker" {
  worker_state_write 10 RUNNING "phase1:implement"
  run worker_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  assert_eq "lists issue 10" "10" "$output"
}

@test "worker_state_list_active: excludes TERMINATED worker" {
  worker_state_write 10 RUNNING "phase1:implement"
  worker_state_write 20 TERMINATED "ci-passed:55"
  run worker_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  assert_eq "only issue 10" "10" "$output"
}

@test "worker_state_list_active: lists multiple non-TERMINATED states" {
  worker_state_write 10 RUNNING "phase1:implement"
  worker_state_write 20 WAITING "phase3:ci-waiting"
  worker_state_write 30 NEW "spawning"
  worker_state_write 40 READY "resume-requested"
  worker_state_write 50 SUSPENDED "checkpoint-saved"
  run worker_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  local count
  count=$(echo "$output" | wc -l | tr -d ' ')
  assert_eq "five active workers" "5" "$count"
}

@test "worker_state_list_active: all TERMINATED returns nothing" {
  worker_state_write 10 TERMINATED "ci-passed:55"
  worker_state_write 20 TERMINATED "crashed:detected-by-gc"
  run worker_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  assert_eq "empty output" "" "$output"
}

@test "worker_state_list_active: works on arbitrary IPC dir (not just session)" {
  local other_dir="${BATS_TEST_TMPDIR}/other-ipc"
  mkdir -p "$other_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${other_dir}/worker-99.state"
  run worker_state_list_active "$other_dir"
  assert_eq "exit 0" "0" "$status"
  assert_eq "lists issue 99" "99" "$output"
}
