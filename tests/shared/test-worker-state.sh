#!/usr/bin/env bash
# test-worker-state.sh — Tests for shared/worker-state.sh state management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: worker-state"

export CEKERNEL_SESSION_ID="test-wstate-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# Source the module under test
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

# ── Test 1: Write NEW state creates state file ──
worker_state_write 50 NEW
assert_file_exists "NEW state creates state file" "${CEKERNEL_IPC_DIR}/worker-50.state"

# ── Test 2: State file content format is STATE:detail ──
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-50.state")
assert_match "State file starts with NEW" '^NEW:' "$CONTENT"

# ── Test 3: Read state returns correct state ──
STATE=$(worker_state_read 50)
assert_match "Read returns state field" '"state":"NEW"' "$STATE"
assert_match "Read returns issue field" '"issue":50' "$STATE"

# ── Test 4: Write READY state ──
worker_state_write 50 READY
STATE=$(worker_state_read 50)
assert_match "State transitions to READY" '"state":"READY"' "$STATE"

# ── Test 5: Write RUNNING state with detail ──
worker_state_write 50 RUNNING "phase1:implement"
STATE=$(worker_state_read 50)
assert_match "State transitions to RUNNING" '"state":"RUNNING"' "$STATE"
assert_match "Detail is included" '"detail":"phase1:implement"' "$STATE"

# ── Test 6: Write WAITING state ──
worker_state_write 50 WAITING "ci"
STATE=$(worker_state_read 50)
assert_match "State transitions to WAITING" '"state":"WAITING"' "$STATE"

# ── Test 7: Write TERMINATED state ──
worker_state_write 50 TERMINATED "merged"
STATE=$(worker_state_read 50)
assert_match "State transitions to TERMINATED" '"state":"TERMINATED"' "$STATE"
assert_match "TERMINATED detail" '"detail":"merged"' "$STATE"

# ── Test 8: Write SUSPENDED state ──
worker_state_write 50 SUSPENDED "checkpoint-saved"
STATE=$(worker_state_read 50)
assert_match "State transitions to SUSPENDED" '"state":"SUSPENDED"' "$STATE"
assert_match "SUSPENDED detail" '"detail":"checkpoint-saved"' "$STATE"

# ── Test 9: Read nonexistent state returns UNKNOWN ──
STATE=$(worker_state_read 999)
assert_match "Missing state returns UNKNOWN" '"state":"UNKNOWN"' "$STATE"

# ── Test 10: Invalid state is rejected ──
EXIT_CODE=0
worker_state_write 50 INVALID 2>/dev/null || EXIT_CODE=$?
assert_eq "Invalid state rejected with exit 1" "1" "$EXIT_CODE"

# ── Test 11: Validation works with modified IFS (issue #141) ──
# When IFS is changed (e.g., IFS=$'\n'), the for-loop word splitting breaks.
# Validation must work regardless of IFS.
OLD_IFS="$IFS"
IFS=$'\n'
EXIT_CODE=0
worker_state_write 50 RUNNING "ifs-test" 2>/dev/null || EXIT_CODE=$?
IFS="$OLD_IFS"
assert_eq "RUNNING accepted with modified IFS" "0" "$EXIT_CODE"

# ── Test 12: Invalid state rejected with modified IFS ──
OLD_IFS="$IFS"
IFS=$'\n'
EXIT_CODE=0
worker_state_write 50 INVALID 2>/dev/null || EXIT_CODE=$?
IFS="$OLD_IFS"
assert_eq "INVALID rejected with modified IFS" "1" "$EXIT_CODE"

# ── Test 13: State file includes timestamp ──
worker_state_write 51 NEW
STATE=$(worker_state_read 51)
assert_match "State includes timestamp" '"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$STATE"

# ── Test 14: worker_state_write fails when CEKERNEL_IPC_DIR is unset (issue #146) ──
SAVED_IPC_DIR="$CEKERNEL_IPC_DIR"
unset CEKERNEL_IPC_DIR
EXIT_CODE=0
ERR_MSG=$(worker_state_write 60 RUNNING "test" 2>&1) || EXIT_CODE=$?
export CEKERNEL_IPC_DIR="$SAVED_IPC_DIR"
assert_eq "write fails with exit 1 when CEKERNEL_IPC_DIR unset" "1" "$EXIT_CODE"
assert_match "write error mentions CEKERNEL_IPC_DIR" "CEKERNEL_IPC_DIR" "$ERR_MSG"

# ── Test 15: worker_state_read fails when CEKERNEL_IPC_DIR is unset (issue #146) ──
unset CEKERNEL_IPC_DIR
EXIT_CODE=0
ERR_MSG=$(worker_state_read 60 2>&1) || EXIT_CODE=$?
export CEKERNEL_IPC_DIR="$SAVED_IPC_DIR"
assert_eq "read fails with exit 1 when CEKERNEL_IPC_DIR unset" "1" "$EXIT_CODE"
assert_match "read error mentions CEKERNEL_IPC_DIR" "CEKERNEL_IPC_DIR" "$ERR_MSG"

# ── Test 16: worker_state_write fails when CEKERNEL_IPC_DIR is empty (issue #146) ──
export CEKERNEL_IPC_DIR=""
EXIT_CODE=0
ERR_MSG=$(worker_state_write 60 RUNNING "test" 2>&1) || EXIT_CODE=$?
export CEKERNEL_IPC_DIR="$SAVED_IPC_DIR"
assert_eq "write fails with exit 1 when CEKERNEL_IPC_DIR empty" "1" "$EXIT_CODE"
assert_match "write error mentions CEKERNEL_IPC_DIR (empty)" "CEKERNEL_IPC_DIR" "$ERR_MSG"

# ── Test 17: worker_state_read fails when CEKERNEL_IPC_DIR is empty (issue #146) ──
export CEKERNEL_IPC_DIR=""
EXIT_CODE=0
ERR_MSG=$(worker_state_read 60 2>&1) || EXIT_CODE=$?
export CEKERNEL_IPC_DIR="$SAVED_IPC_DIR"
assert_eq "read fails with exit 1 when CEKERNEL_IPC_DIR empty" "1" "$EXIT_CODE"
assert_match "read error mentions CEKERNEL_IPC_DIR (empty)" "CEKERNEL_IPC_DIR" "$ERR_MSG"

report_results
