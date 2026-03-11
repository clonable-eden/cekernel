#!/usr/bin/env bash
# test-watch-state-fallback.sh — watch.sh detects completion via state file when FIFO is absent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch (state file fallback — no FIFO)"

export CEKERNEL_SESSION_ID="test-watch-fallback-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

ISSUE_NUMBER=30

cleanup() {
  rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
  rm -rf "$CEKERNEL_IPC_DIR"
}
trap cleanup EXIT

# Setup: Create session directory but NO FIFO — only state file
mkdir -p "$CEKERNEL_IPC_DIR/logs"

# Pre-write TERMINATED state (simulates Worker that completed but FIFO was missing)
worker_state_write "$ISSUE_NUMBER" TERMINATED "merged"

# ── Test: watch.sh detects completion via state file fallback ──
RESULT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

# Use short poll interval and timeout for test speed
export CEKERNEL_POLL_INTERVAL=1
export CEKERNEL_WORKER_TIMEOUT=10

bash "${CEKERNEL_DIR}/scripts/orchestrator/watch.sh" "$ISSUE_NUMBER" > "$RESULT_FILE" 2>"$STDERR_FILE" &
WATCH_PID=$!

# Poll for watch completion (up to 15 seconds)
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
  echo "  FAIL: watch timed out — state fallback not working"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  report_results
  exit "$TESTS_FAILED"
fi

wait "$WATCH_PID" 2>/dev/null || true

RESULT=$(cat "$RESULT_FILE")
STDERR=$(cat "$STDERR_FILE")
rm -f "$RESULT_FILE" "$STDERR_FILE"

# Verify result JSON
assert_match "Result contains issue number" '"issue":30' "$RESULT"
assert_match "Result contains merged result" '"result":"merged"' "$RESULT"
assert_match "Result contains fallback marker" 'detected-via-state-fallback' "$RESULT"

# Verify stderr warning
assert_match "Warning about state fallback in stderr" 'state file' "$STDERR"

report_results
