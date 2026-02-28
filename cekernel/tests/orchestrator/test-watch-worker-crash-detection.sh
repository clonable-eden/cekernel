#!/usr/bin/env bash
# test-watch-worker-crash-detection.sh — watch-worker.sh detects Worker process crash
#
# When state is not TERMINATED and backend_worker_alive returns false,
# watch-worker.sh should detect the crash and exit immediately with an error result.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch-worker (crash detection — dead process)"

export CEKERNEL_SESSION_ID="test-watch-crash-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

ISSUE_NUMBER=40

cleanup() {
  rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
  rm -rf "$CEKERNEL_IPC_DIR"
}
trap cleanup EXIT

# Setup: Create session directory with logs, NO FIFO
mkdir -p "$CEKERNEL_IPC_DIR/logs"

# Write RUNNING state (simulates Worker that was running but then crashed)
worker_state_write "$ISSUE_NUMBER" RUNNING "phase1:implement"

# Create a handle file pointing to a dead PID (PID 99999 is almost certainly not running)
# Use headless backend so backend_worker_alive checks kill -0 $PID
echo "99999" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE_NUMBER}"

RESULT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

# Use short poll interval and timeout for test speed
# Use headless backend so backend_worker_alive checks kill -0 $PID
export CEKERNEL_POLL_INTERVAL=1
export CEKERNEL_WORKER_TIMEOUT=10
export CEKERNEL_BACKEND=headless

bash "${CEKERNEL_DIR}/scripts/orchestrator/watch-worker.sh" "$ISSUE_NUMBER" > "$RESULT_FILE" 2>"$STDERR_FILE" &
WATCH_PID=$!

# Poll for watch-worker completion (up to 15 seconds)
# It should detect the crash within 1-2 poll intervals, not wait for timeout
WATCH_DONE=0
for _ in $(seq 1 150); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

if [[ "$WATCH_DONE" -eq 0 ]]; then
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  rm -f "$RESULT_FILE" "$STDERR_FILE"
  echo "  FAIL: watch-worker timed out — crash detection not working"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  report_results
  exit "$TESTS_FAILED"
fi

wait "$WATCH_PID" 2>/dev/null || true

RESULT=$(cat "$RESULT_FILE")
STDERR=$(cat "$STDERR_FILE")
rm -f "$RESULT_FILE" "$STDERR_FILE"

# Verify result JSON indicates crash
assert_match "Result contains issue number" '"issue":40' "$RESULT"
assert_match "Result contains crash status" '"status":"crashed"' "$RESULT"

# Verify log file has WORKER_CRASH event
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
if [[ -f "$LOG_FILE" ]]; then
  LOG_CONTENT=$(cat "$LOG_FILE")
  assert_match "WORKER_CRASH logged" "WORKER_CRASH" "$LOG_CONTENT"
else
  echo "  FAIL: Log file not found: $LOG_FILE"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

report_results
