#!/usr/bin/env bash
# test-watch-workers.sh — watch-workers test within session scope
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch-workers (session-scoped)"

export CEKERNEL_SESSION_ID="test-watch-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

ISSUES=(20 21)

cleanup() {
  for issue in "${ISSUES[@]}"; do
    rm -f "${CEKERNEL_IPC_DIR}/worker-${issue}"
  done
  rmdir "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup: Create FIFOs in session directory
mkdir -p "$CEKERNEL_IPC_DIR"
for issue in "${ISSUES[@]}"; do
  mkfifo "${CEKERNEL_IPC_DIR}/worker-${issue}"
done

# ── Test: watch-workers.sh monitors session-scoped FIFOs in parallel ──
RESULT_FILE=$(mktemp)

# Launch watch-workers in background
bash "${CEKERNEL_DIR}/scripts/orchestrator/watch-workers.sh" "${ISSUES[@]}" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# Wait for watch-workers to open FIFOs
sleep 0.5

# Write to each FIFO
WRITER_PIDS=()
for issue in "${ISSUES[@]}"; do
  bash -c "echo '{\"issue\":${issue},\"status\":\"merged\",\"detail\":\"PR-${issue}\"}' > '${CEKERNEL_IPC_DIR}/worker-${issue}'" &
  WRITER_PIDS+=($!)
done

# Poll for watch-workers completion (up to 5 seconds)
WATCH_DONE=0
for _ in $(seq 1 50); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

# Kill remaining writers after watch-workers finishes (they may block without a reader)
for pid in "${WRITER_PIDS[@]}"; do
  kill "$pid" 2>/dev/null || true
done
# Delete FIFOs after kill to unblock open()
for issue in "${ISSUES[@]}"; do
  rm -f "${CEKERNEL_IPC_DIR}/worker-${issue}"
done
for pid in "${WRITER_PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done
wait "$WATCH_PID" 2>/dev/null || true

if [[ "$WATCH_DONE" -eq 0 ]]; then
  rm -f "$RESULT_FILE"
  echo "  FAIL: watch-workers timed out (not reading session FIFOs)"
  ((TESTS_FAILED++)) || true
  report_results
  exit "$TESTS_FAILED"
fi

# Verify results
RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Issue 20 result received" '"issue":20' "$RESULT"
assert_match "Issue 21 result received" '"issue":21' "$RESULT"
assert_match "Issue 20 merged (not error)" '"status":"merged"' "$RESULT"

report_results
