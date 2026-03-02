#!/usr/bin/env bash
# test-notify-complete-no-fifo.sh — notify-complete.sh writes state even when FIFO is missing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: notify-complete (no FIFO — state-first ordering)"

# Test session
export CEKERNEL_SESSION_ID="test-notify-nofifo-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

ISSUE_NUMBER=50
mkdir -p "$CEKERNEL_IPC_DIR/logs"

# No FIFO created — this is the bug scenario

# ── Test 1: notify-complete.sh exits 0 (not 1) when FIFO is missing ──
EXIT_CODE=0
STDERR_OUTPUT=$(bash "${CEKERNEL_DIR}/scripts/worker/notify-complete.sh" "$ISSUE_NUMBER" merged 99 2>&1) || EXIT_CODE=$?

assert_eq "notify-complete.sh exits 0 when FIFO missing" "0" "$EXIT_CODE"

# ── Test 2: State file is written as TERMINATED even without FIFO ──
STATE_JSON=$(worker_state_read "$ISSUE_NUMBER")
STATE=$(echo "$STATE_JSON" | jq -r '.state')
DETAIL=$(echo "$STATE_JSON" | jq -r '.detail')

assert_eq "State is TERMINATED" "TERMINATED" "$STATE"
assert_eq "Detail is merged" "merged" "$DETAIL"

# ── Test 3: Warning about missing FIFO is logged to stderr ──
assert_match "Warning about FIFO missing in stderr" "FIFO not found" "$STDERR_OUTPUT"

# ── Test 4: FIFO_MISSING event is logged to log file ──
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
if [[ -f "$LOG_FILE" ]]; then
  LOG_CONTENT=$(cat "$LOG_FILE")
  assert_match "FIFO_MISSING logged" "FIFO_MISSING" "$LOG_CONTENT"
else
  echo "  FAIL: Log file not found: $LOG_FILE"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Cleanup
rm -rf "$CEKERNEL_IPC_DIR"

report_results
