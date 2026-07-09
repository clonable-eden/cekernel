#!/usr/bin/env bash
# test-watch.sh — watch test within session scope (state file path)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch (session-scoped, state file path)"

export CEKERNEL_SESSION_ID="test-watch-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

ISSUES=(20 21)

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR"
}
trap cleanup EXIT

# Setup: Create session directory with state files
mkdir -p "${CEKERNEL_IPC_DIR}/logs"
for issue in "${ISSUES[@]}"; do
  worker_state_write "$issue" RUNNING "phase1:implement"
done

# ── Test: watch.sh monitors session-scoped state files in parallel ──
RESULT_FILE=$(mktemp)

# Use short poll intervals for test speed
export CEKERNEL_STATE_POLL_INTERVAL=1
export CEKERNEL_POLL_INTERVAL=30
export CEKERNEL_WORKER_TIMEOUT=15

# Launch watch in background
bash "${CEKERNEL_DIR}/scripts/orchestrator/watch.sh" "${ISSUES[@]}" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# Wait for watch to start polling
sleep 1

# Write TERMINATED state for each issue
for issue in "${ISSUES[@]}"; do
  worker_state_write "$issue" TERMINATED "merged:PR-${issue}"
done

# Poll for watch completion (up to 10 seconds)
WATCH_DONE=0
for _ in $(seq 1 100); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

wait "$WATCH_PID" 2>/dev/null || true

if [[ "$WATCH_DONE" -eq 0 ]]; then
  kill "$WATCH_PID" 2>/dev/null || true
  rm -f "$RESULT_FILE"
  echo "  FAIL: watch timed out (not detecting state file changes)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  report_results
  exit "$TESTS_FAILED"
fi

# Verify results
RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Issue 20 result received" '"issue":20' "$RESULT"
assert_match "Issue 21 result received" '"issue":21' "$RESULT"
assert_match "Issue 20 merged" '"result":"merged"' "$RESULT"

report_results
