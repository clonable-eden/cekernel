#!/usr/bin/env bash
# test-watch-fifo-logging.sh — watch.sh logs FIFO lifecycle events
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch (FIFO lifecycle logging)"

export CEKERNEL_SESSION_ID="test-watch-log-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

ISSUE_NUMBER=31

cleanup() {
  rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
  rm -rf "$CEKERNEL_IPC_DIR"
}
trap cleanup EXIT

# Setup: Create FIFO and log directory
mkdir -p "$CEKERNEL_IPC_DIR/logs"
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"

RESULT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

export CEKERNEL_POLL_INTERVAL=1
export CEKERNEL_WORKER_TIMEOUT=10

# Launch watch in background
bash "${CEKERNEL_DIR}/scripts/orchestrator/watch.sh" "$ISSUE_NUMBER" > "$RESULT_FILE" 2>"$STDERR_FILE" &
WATCH_PID=$!

# Wait for watch to open FIFO
sleep 0.5

# Write completion to FIFO
echo '{"issue":31,"status":"merged","detail":"PR-31","timestamp":"2026-01-01T00:00:00Z"}' > "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}" &
WRITER_PID=$!

# Poll for watch completion (up to 5 seconds)
WATCH_DONE=0
for _ in $(seq 1 50); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

kill "$WRITER_PID" 2>/dev/null || true
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
wait "$WRITER_PID" 2>/dev/null || true

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

# Verify log file has FIFO lifecycle events
if [[ -f "$LOG_FILE" ]]; then
  LOG_CONTENT=$(cat "$LOG_FILE")
  assert_match "FIFO_WATCH_START logged" "FIFO_WATCH_START" "$LOG_CONTENT"
  assert_match "FIFO_READ logged" "FIFO_READ" "$LOG_CONTENT"
else
  echo "  FAIL: Log file not found: $LOG_FILE"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: FIFO_WATCH_START not verifiable (no log file)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

rm -f "$RESULT_FILE" "$STDERR_FILE"

report_results
