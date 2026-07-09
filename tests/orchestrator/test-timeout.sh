#!/usr/bin/env bash
# test-timeout.sh — watch timeout mechanism tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: timeout"

export CEKERNEL_SESSION_ID="test-timeout-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

ISSUE=99

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR"
}
trap cleanup EXIT

mkdir -p "${CEKERNEL_IPC_DIR}/logs"
worker_state_write "$ISSUE" RUNNING "phase1:implement"

# ── Test 1: Timeout returns appropriate JSON ──
RESULT_FILE=$(mktemp)

# Launch watch with 2s timeout (state stays RUNNING)
CEKERNEL_WORKER_TIMEOUT=2 CEKERNEL_STATE_POLL_INTERVAL=1 \
  bash "${CEKERNEL_DIR}/scripts/orchestrator/watch.sh" "$ISSUE" > "$RESULT_FILE" 2>/dev/null &
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

assert_eq "watch exited within timeout" "1" "$WATCH_DONE"

RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Timeout result in result" '"result":"timeout"' "$RESULT"
assert_match "Issue number in result" '"issue":99' "$RESULT"
assert_match "Timeout detail in result" 'No response within' "$RESULT"

# ── Test 2: Normal completion returns before timeout ──
# Reset state to RUNNING
worker_state_write "$ISSUE" RUNNING "phase1:implement"

RESULT_FILE=$(mktemp)

CEKERNEL_WORKER_TIMEOUT=10 CEKERNEL_STATE_POLL_INTERVAL=1 \
  bash "${CEKERNEL_DIR}/scripts/orchestrator/watch.sh" "$ISSUE" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# Wait for watch to start polling, then write TERMINATED
sleep 2
worker_state_write "$ISSUE" TERMINATED "merged:PR-99"

# Poll for completion (should complete within 5 seconds)
WATCH_DONE=0
for _ in $(seq 1 50); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

wait "$WATCH_PID" 2>/dev/null || true

assert_eq "Completed before timeout" "1" "$WATCH_DONE"

RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Normal result contains merged" '"result":"merged"' "$RESULT"

report_results
