#!/usr/bin/env bats
# worker-priority.bats — bats-core tests for scripts/shared/worker-priority.sh
#
# Verifies priority write/read, named priority resolution, numeric range
# validation, and default behavior.

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"

  source "${CEKERNEL_DIR}/scripts/shared/worker-priority.sh"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "write numeric priority creates file with correct value" {
  worker_priority_write 60 10
  assert_file_exists "priority file created" "${CEKERNEL_IPC_DIR}/worker-60.priority"
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/worker-60.priority")
  assert_eq "value is 10" "10" "$content"
}

@test "read priority returns correct JSON" {
  worker_priority_write 60 10
  local result
  result=$(worker_priority_read 60)
  assert_match "priority field" '"priority":10' "$result"
  assert_match "issue field" '"issue":60' "$result"
  assert_match "priority_name field" '"priority_name":"normal"' "$result"
}

@test "named priority critical resolves to 0" {
  worker_priority_write 61 critical
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/worker-61.priority")
  assert_eq "critical = 0" "0" "$content"
}

@test "named priority high resolves to 5" {
  worker_priority_write 62 high
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/worker-62.priority")
  assert_eq "high = 5" "5" "$content"
}

@test "named priority normal resolves to 10" {
  worker_priority_write 63 normal
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/worker-63.priority")
  assert_eq "normal = 10" "10" "$content"
}

@test "named priority low resolves to 15" {
  worker_priority_write 64 low
  local content
  content=$(cat "${CEKERNEL_IPC_DIR}/worker-64.priority")
  assert_eq "low = 15" "15" "$content"
}

@test "read nonexistent priority returns default normal/10" {
  local result
  result=$(worker_priority_read 999)
  assert_match "default priority 10" '"priority":10' "$result"
  assert_match "default name normal" '"priority_name":"normal"' "$result"
}

@test "invalid priority name is rejected" {
  run worker_priority_write 65 invalid
  assert_eq "exit 1" "1" "$status"
}

@test "out of range numeric priority (20) is rejected" {
  run worker_priority_write 66 20
  assert_eq "exit 1" "1" "$status"
}

@test "negative numeric priority is rejected" {
  run worker_priority_write 67 -1
  assert_eq "exit 1" "1" "$status"
}

@test "priority 0 maps to critical" {
  worker_priority_write 68 0
  local result
  result=$(worker_priority_read 68)
  assert_match "0 = critical" '"priority_name":"critical"' "$result"
}

@test "priority 19 maps to low" {
  worker_priority_write 69 19
  local result
  result=$(worker_priority_read 69)
  assert_match "19 = low" '"priority_name":"low"' "$result"
}

@test "priority 7 maps to high" {
  worker_priority_write 70 7
  local result
  result=$(worker_priority_read 70)
  assert_match "7 = high" '"priority_name":"high"' "$result"
}

@test "priority 12 maps to normal" {
  worker_priority_write 71 12
  local result
  result=$(worker_priority_read 71)
  assert_match "12 = normal" '"priority_name":"normal"' "$result"
}

@test "overwrite existing priority" {
  worker_priority_write 60 10
  worker_priority_write 60 high
  local result
  result=$(worker_priority_read 60)
  assert_match "overwritten to 5" '"priority":5' "$result"
}
