#!/usr/bin/env bash
# test-timeout.sh — watch-worker timeout mechanism tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: timeout"

export CEKERNEL_SESSION_ID="test-timeout-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

ISSUE=99

cleanup() {
  rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
  rmdir "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"

# ── Test 1: Timeout returns appropriate JSON ──
RESULT_FILE=$(mktemp)

# Launch watch-worker with 2s timeout (Writer does not write)
CEKERNEL_WORKER_TIMEOUT=2 \
  bash "${CEKERNEL_DIR}/scripts/orchestrator/watch-worker.sh" "$ISSUE" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# Poll for completion (up to 10 seconds)
WATCH_DONE=0
for _ in $(seq 1 100); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

wait "$WATCH_PID" 2>/dev/null || true

assert_eq "watch-worker exited within timeout" "1" "$WATCH_DONE"

RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Timeout status in result" '"status":"timeout"' "$RESULT"
assert_match "Issue number in result" '"issue":99' "$RESULT"
assert_match "Timeout detail in result" 'No response within' "$RESULT"

# ── Test 2: Normal completion returns before timeout ──
# Recreate FIFO (deleted by watch_one in Test 1)
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"

RESULT_FILE=$(mktemp)

CEKERNEL_WORKER_TIMEOUT=10 \
  bash "${CEKERNEL_DIR}/scripts/orchestrator/watch-worker.sh" "$ISSUE" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# Wait for watch-worker to open FIFO
sleep 0.5

# Write immediately
echo '{"issue":99,"status":"merged","detail":"PR-99"}' > "${CEKERNEL_IPC_DIR}/worker-${ISSUE}" &
WRITER_PID=$!

# Poll for completion (should complete within 3 seconds)
WATCH_DONE=0
for _ in $(seq 1 30); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

kill "$WRITER_PID" 2>/dev/null || true
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
wait "$WRITER_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true

assert_eq "Completed before timeout" "1" "$WATCH_DONE"

RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Normal result contains merged" '"status":"merged"' "$RESULT"

report_results
