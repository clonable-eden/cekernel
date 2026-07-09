#!/usr/bin/env bash
# test-watch-fifo-logging.sh — watch.sh logs lifecycle events (WATCH_START, STATE_COMPLETE)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch (lifecycle logging)"

export CEKERNEL_SESSION_ID="test-watch-log-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

ISSUE_NUMBER=31

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR"
}
trap cleanup EXIT

# Setup: Create state file and log directory
mkdir -p "$CEKERNEL_IPC_DIR/logs"
worker_state_write "$ISSUE_NUMBER" RUNNING "phase1:implement"

RESULT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

export CEKERNEL_STATE_POLL_INTERVAL=1
export CEKERNEL_POLL_INTERVAL=30
export CEKERNEL_WORKER_TIMEOUT=10

# Launch watch in background
bash "${CEKERNEL_DIR}/scripts/orchestrator/watch.sh" "$ISSUE_NUMBER" > "$RESULT_FILE" 2>"$STDERR_FILE" &
WATCH_PID=$!

# Wait for watch to start, then write completion
sleep 2
worker_state_write "$ISSUE_NUMBER" TERMINATED "merged:PR-31"

# Poll for watch completion (up to 10 seconds)
WATCH_DONE=0
for _ in $(seq 1 100); do
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
  echo "  FAIL: watch timed out"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  report_results
  exit "$TESTS_FAILED"
fi

wait "$WATCH_PID" 2>/dev/null || true

STDERR=$(cat "$STDERR_FILE")
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"

# Verify log file has lifecycle events
if [[ -f "$LOG_FILE" ]]; then
  LOG_CONTENT=$(cat "$LOG_FILE")
  assert_match "WATCH_START logged" "WATCH_START" "$LOG_CONTENT"
  assert_match "STATE_COMPLETE logged" "STATE_COMPLETE" "$LOG_CONTENT"
else
  echo "  FAIL: Log file not found: $LOG_FILE"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: WATCH_START not verifiable (no log file)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

rm -f "$RESULT_FILE" "$STDERR_FILE"

report_results
