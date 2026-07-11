#!/usr/bin/env bats
# reviewer-state.bats — bats-core tests for reviewer state management (#627)
#
# reviewer_state_write / reviewer_state_read / reviewer_state_list_active
# manage reviewer-<issue>.state files, kept separate from worker-*.state
# to avoid interference with worker-specific machinery (spawn count,
# health-check, gc worker sweep — OQ1/OQ2 of ADR-0021).

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  source "${CEKERNEL_DIR}/scripts/shared/reviewer-state.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

# ── reviewer_state_write ──

@test "reviewer_state_write creates reviewer-<issue>.state file" {
  reviewer_state_write 42 REVIEWING "review:in-progress"
  assert_file_exists "state file created" "${CEKERNEL_IPC_DIR}/reviewer-42.state"
}

@test "reviewer_state_write format is STATE:TIMESTAMP:detail" {
  reviewer_state_write 42 REVIEWING "review:in-progress"
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/reviewer-42.state")
  assert_match "starts with REVIEWING" "^REVIEWING:" "$content"
  assert_match "has ISO timestamp" "^REVIEWING:[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$content"
  assert_match "ends with detail" "review:in-progress$" "$content"
}

@test "reviewer_state_write validates state (only REVIEWING/TERMINATED)" {
  run reviewer_state_write 42 RUNNING "invalid"
  assert_eq "invalid state: exit 1" "1" "$status"
  run reviewer_state_write 42 REVIEWING "valid"
  assert_eq "REVIEWING: exit 0" "0" "$status"
  run reviewer_state_write 42 TERMINATED "approved"
  assert_eq "TERMINATED: exit 0" "0" "$status"
}

@test "reviewer_state_write validates verdict for TERMINATED state" {
  # Valid verdicts: approved, changes-requested, failed
  run reviewer_state_write 42 TERMINATED "approved"
  assert_eq "approved: exit 0" "0" "$status"
  run reviewer_state_write 42 TERMINATED "changes-requested"
  assert_eq "changes-requested: exit 0" "0" "$status"
  run reviewer_state_write 42 TERMINATED "failed"
  assert_eq "failed: exit 0" "0" "$status"

  # Invalid verdicts: unverified, escalated, anything else
  run reviewer_state_write 42 TERMINATED "unverified"
  assert_eq "unverified: exit 1" "1" "$status"
  run reviewer_state_write 42 TERMINATED "escalated"
  assert_eq "escalated: exit 1" "1" "$status"
  run reviewer_state_write 42 TERMINATED "APPROVED"
  assert_eq "APPROVED (uppercase): exit 1" "1" "$status"
  run reviewer_state_write 42 TERMINATED ""
  assert_eq "empty verdict: exit 1" "1" "$status"
}

@test "reviewer_state_write allows any detail for REVIEWING state" {
  # REVIEWING does not enforce verdict enum — detail is freeform
  run reviewer_state_write 42 REVIEWING "review:in-progress"
  assert_eq "review:in-progress: exit 0" "0" "$status"
  run reviewer_state_write 42 REVIEWING "anything"
  assert_eq "anything: exit 0" "0" "$status"
  run reviewer_state_write 42 REVIEWING ""
  assert_eq "empty: exit 0" "0" "$status"
}

@test "reviewer_state_write errors without CEKERNEL_IPC_DIR" {
  unset CEKERNEL_IPC_DIR
  run reviewer_state_write 42 REVIEWING "test"
  assert_eq "exit 1" "1" "$status"
}

# ── reviewer_state_read ──

@test "reviewer_state_read returns JSON with issue, state, detail, timestamp" {
  reviewer_state_write 42 REVIEWING "review:in-progress"
  run reviewer_state_read 42
  assert_eq "exit 0" "0" "$status"
  assert_match "contains issue" '"issue":42' "$output"
  assert_match "contains state" '"state":"REVIEWING"' "$output"
  assert_match "contains detail" '"detail":"review:in-progress"' "$output"
  assert_match "contains timestamp" '"timestamp":"20' "$output"
}

@test "reviewer_state_read returns UNKNOWN for missing file" {
  run reviewer_state_read 99
  assert_eq "exit 0" "0" "$status"
  assert_match "state is UNKNOWN" '"state":"UNKNOWN"' "$output"
}

@test "reviewer_state_read parses TERMINATED with verdict" {
  reviewer_state_write 42 TERMINATED "approved"
  run reviewer_state_read 42
  assert_match "state is TERMINATED" '"state":"TERMINATED"' "$output"
  assert_match "detail is approved" '"detail":"approved"' "$output"
}

# ── reviewer_state_list_active ──

@test "reviewer_state_list_active: empty dir returns nothing" {
  run reviewer_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  assert_eq "empty output" "" "$output"
}

@test "reviewer_state_list_active: lists REVIEWING reviewer" {
  reviewer_state_write 42 REVIEWING "review:in-progress"
  run reviewer_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  assert_eq "lists issue 42" "42" "$output"
}

@test "reviewer_state_list_active: excludes TERMINATED reviewer" {
  reviewer_state_write 42 REVIEWING "review:in-progress"
  reviewer_state_write 43 TERMINATED "approved"
  run reviewer_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "exit 0" "0" "$status"
  assert_eq "only issue 42" "42" "$output"
}

@test "reviewer_state_list_active: does NOT include worker-*.state" {
  # Ensure reviewer enumeration is isolated from worker state
  source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"
  worker_state_write 10 RUNNING "phase1:implement"
  reviewer_state_write 42 REVIEWING "review:in-progress"
  run reviewer_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "only reviewer issue" "42" "$output"
}

# ── Isolation: worker_state_list_active does NOT include reviewer-*.state ──

@test "worker_state_list_active ignores reviewer-*.state files" {
  source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"
  worker_state_write 10 RUNNING "phase1:implement"
  reviewer_state_write 42 REVIEWING "review:in-progress"
  run worker_state_list_active "$CEKERNEL_IPC_DIR"
  assert_eq "only worker issue" "10" "$output"
}
