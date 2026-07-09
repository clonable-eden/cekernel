#!/usr/bin/env bats
# process-status.bats — bats-core tests for scripts/orchestrator/process-status.sh
#
# Consolidates (ADR-0017 Decision 4):
#   tests/orchestrator/test-process-status.sh          — core JSON output
#   tests/orchestrator/test-process-status-state.sh    — state field integration
#   tests/orchestrator/test-process-status-priority.sh — priority field integration

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  STATUS_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/process-status.sh"

  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  mkdir -p "$CEKERNEL_IPC_DIR"

  source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"
  source "${CEKERNEL_DIR}/scripts/shared/worker-priority.sh"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR"
}

# ── Core JSON output (from test-process-status.sh) ──

@test "no workers: empty output" {
  run bash "$STATUS_SCRIPT"
  assert_eq "exit 0" "0" "$status"
  assert_eq "empty output" "" "$output"
}

@test "one worker: one JSON line with issue and uptime" {
  worker_state_write 20 RUNNING "working"
  run bash "$STATUS_SCRIPT"
  local line_count
  line_count=$(echo "$output" | grep -c 'issue' || true)
  assert_eq "one JSON line" "1" "$line_count"
  assert_match "output contains issue 20" '"issue":20' "$output"
  assert_match "output contains uptime field" '"uptime":' "$output"
}

@test "three workers: three JSON lines" {
  worker_state_write 20 RUNNING "working"
  worker_state_write 21 RUNNING "working"
  worker_state_write 22 RUNNING "working"
  run bash "$STATUS_SCRIPT"
  local line_count
  line_count=$(echo "$output" | grep -c 'issue')
  assert_eq "three JSON lines" "3" "$line_count"
}

@test "missing session directory: exit 1" {
  rm -rf "$CEKERNEL_IPC_DIR"
  run bash "$STATUS_SCRIPT"
  assert_eq "exit 1" "1" "$status"
}

@test "type field reads worker/reviewer from .type file, defaults to unknown" {
  worker_state_write 50 RUNNING "working"
  echo "worker" > "${CEKERNEL_IPC_DIR}/worker-50.type"
  worker_state_write 51 RUNNING "reviewing"
  echo "reviewer" > "${CEKERNEL_IPC_DIR}/worker-51.type"
  worker_state_write 52 RUNNING "working"

  run bash "$STATUS_SCRIPT"
  assert_match "type worker" '"type":"worker"' "$(echo "$output" | grep '"issue":50')"
  assert_match "type reviewer" '"type":"reviewer"' "$(echo "$output" | grep '"issue":51')"
  assert_match "missing type file shows unknown" '"type":"unknown"' "$(echo "$output" | grep '"issue":52')"
}

@test "uptime reads from .spawned file (not state file stat)" {
  worker_state_write 60 RUNNING "working"
  echo "worker" > "${CEKERNEL_IPC_DIR}/worker-60.type"
  # Epoch 0 in .spawned forces a very large uptime (many hours).
  echo "0" > "${CEKERNEL_IPC_DIR}/worker-60.spawned"
  run bash "$STATUS_SCRIPT"
  assert_match "uptime from .spawned (epoch 0 → hours)" '"uptime":"[0-9]+h' "$(echo "$output" | grep '"issue":60')"
}

# ── State field integration (from test-process-status-state.sh) ──

@test "state and state_detail read from state file" {
  worker_state_write 30 RUNNING "phase1:implement"
  run bash "$STATUS_SCRIPT"
  assert_match "state field" '"state":"RUNNING"' "$output"
  assert_match "state detail" '"state_detail":"phase1:implement"' "$output"
}

# ── Priority field integration (from test-process-status-priority.sh) ──

@test "priority file values are shown (high/critical/low)" {
  worker_state_write 40 RUNNING "working"
  worker_priority_write 40 high
  worker_state_write 42 RUNNING "working"
  worker_priority_write 42 critical
  worker_state_write 43 RUNNING "working"
  worker_priority_write 43 low

  run bash "$STATUS_SCRIPT"
  local line40 line42 line43
  line40=$(echo "$output" | grep '"issue":40')
  line42=$(echo "$output" | grep '"issue":42')
  line43=$(echo "$output" | grep '"issue":43')
  assert_match "high priority value" '"priority":5' "$line40"
  assert_match "high priority name" '"priority_name":"high"' "$line40"
  assert_match "critical priority value" '"priority":0' "$line42"
  assert_match "critical priority name" '"priority_name":"critical"' "$line42"
  assert_match "low priority value" '"priority":15' "$line43"
}

@test "missing priority file shows default (normal/10)" {
  worker_state_write 41 RUNNING "working"
  run bash "$STATUS_SCRIPT"
  local line41
  line41=$(echo "$output" | grep '"issue":41')
  assert_match "default priority 10" '"priority":10' "$line41"
  assert_match "default priority name normal" '"priority_name":"normal"' "$line41"
}

# ── ADR-0020 Phase 2: state-based enumeration ──

@test "enumerates by state file (ADR-0020 Phase 2)" {
  worker_state_write 70 RUNNING "phase1:implement"
  run bash "$STATUS_SCRIPT"
  assert_match "worker listed by state file" '"issue":70' "$output"
  assert_match "state shown" '"state":"RUNNING"' "$output"
}

@test "excludes TERMINATED workers (ADR-0020 Phase 2)" {
  worker_state_write 71 RUNNING "phase1:implement"
  worker_state_write 72 TERMINATED "ci-passed:55"
  run bash "$STATUS_SCRIPT"
  local line_count
  line_count=$(echo "$output" | grep -c '"issue"' || true)
  assert_eq "only non-TERMINATED listed" "1" "$line_count"
  assert_match "active worker listed" '"issue":71' "$output"
}

@test "output does not contain fifo field (ADR-0020 Phase 2)" {
  worker_state_write 73 RUNNING "phase1:implement"
  run bash "$STATUS_SCRIPT"
  if [[ "$output" == *'"fifo"'* ]]; then
    echo "FAIL: output should not contain fifo field" >&2
    return 1
  fi
}
