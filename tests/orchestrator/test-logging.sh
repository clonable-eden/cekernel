#!/usr/bin/env bash
# test-logging.sh — Structured log creation, writing, and cleanup tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: logging"

# Test session
export CEKERNEL_SESSION_ID="test-logging-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

LOG_DIR="${CEKERNEL_IPC_DIR}/logs"
ISSUE_NUMBER=80

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Clean up state from previous test runs
cleanup

# ── Test 1: Log directory and file creation ──
mkdir -p "$CEKERNEL_IPC_DIR"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/worker-${ISSUE_NUMBER}.log"

# Simulate SPAWN event
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SPAWN issue=#${ISSUE_NUMBER} branch=issue/${ISSUE_NUMBER}-test" >> "$LOG_FILE"

assert_dir_exists "Log directory created" "$LOG_DIR"
assert_file_exists "Log file created on SPAWN" "$LOG_FILE"

# ── Test 2: SPAWN event format verification ──
SPAWN_LINE=$(head -1 "$LOG_FILE")
assert_match "SPAWN has ISO8601 timestamp" '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' "$SPAWN_LINE"
assert_match "SPAWN has event type" 'SPAWN' "$SPAWN_LINE"
assert_match "SPAWN has issue number" "issue=#${ISSUE_NUMBER}" "$SPAWN_LINE"
assert_match "SPAWN has branch" 'branch=' "$SPAWN_LINE"

# ── Test 3: notify-complete.sh records COMPLETE in log ──
# Set up FIFO (required by notify-complete.sh)
FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
mkfifo "$FIFO"

# Background FIFO reader (to unblock write)
(cat "$FIFO" > /dev/null) &
READER_PID=$!

# Run notify-complete.sh
bash "${CEKERNEL_DIR}/scripts/process/notify-complete.sh" "$ISSUE_NUMBER" merged 99

wait "$READER_PID" || true

COMPLETE_LINE=$(tail -1 "$LOG_FILE")
assert_match "COMPLETE has ISO8601 timestamp" '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' "$COMPLETE_LINE"
assert_match "COMPLETE has event type" 'COMPLETE' "$COMPLETE_LINE"
assert_match "COMPLETE has result" 'result=merged' "$COMPLETE_LINE"
assert_match "COMPLETE has detail" 'detail=99' "$COMPLETE_LINE"

# ── Test 4: FAILED event recording ──
ISSUE_FAIL=81
LOG_FILE_FAIL="${LOG_DIR}/worker-${ISSUE_FAIL}.log"
FIFO_FAIL="${CEKERNEL_IPC_DIR}/worker-${ISSUE_FAIL}"

# Prepare log file and FIFO
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SPAWN issue=#${ISSUE_FAIL} branch=issue/${ISSUE_FAIL}-fail" >> "$LOG_FILE_FAIL"
mkfifo "$FIFO_FAIL"

(cat "$FIFO_FAIL" > /dev/null) &
READER_PID=$!

bash "${CEKERNEL_DIR}/scripts/process/notify-complete.sh" "$ISSUE_FAIL" failed "CI failed 3 times"

wait "$READER_PID" || true

FAILED_LINE=$(tail -1 "$LOG_FILE_FAIL")
assert_match "FAILED event recorded" 'FAILED' "$FAILED_LINE"
assert_match "FAILED has result" 'result=failed' "$FAILED_LINE"
assert_match "FAILED has detail" 'detail=CI failed 3 times' "$FAILED_LINE"

# ── Test 5: watch-logs.sh returns error with nonexistent log directory ──
SAVE_CEKERNEL_SESSION_ID="$CEKERNEL_SESSION_ID"
export CEKERNEL_SESSION_ID="nonexistent-session-00000000"
if bash "${CEKERNEL_DIR}/scripts/orchestrator/watch-logs.sh" 2>/dev/null; then
  echo "  FAIL: watch-logs.sh should fail with no log dir"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: watch-logs.sh fails with no log dir"
  ((TESTS_PASSED++)) || true
fi
export CEKERNEL_SESSION_ID="$SAVE_CEKERNEL_SESSION_ID"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Test 5b: watch-logs.sh returns error for nonexistent issue ──
if bash "${CEKERNEL_DIR}/scripts/orchestrator/watch-logs.sh" 999 2>/dev/null; then
  echo "  FAIL: watch-logs.sh should fail for nonexistent issue"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: watch-logs.sh fails for nonexistent issue"
  ((TESTS_PASSED++)) || true
fi

# ── Test 6: Log file cleanup ──
# Verify cleanup target log file exists
assert_file_exists "Log file exists before cleanup" "$LOG_FILE"

# Simulate log cleanup portion of cleanup-worktree.sh
rm -f "$LOG_FILE"
rm -f "$LOG_FILE_FAIL"
rmdir "$LOG_DIR" 2>/dev/null || true

assert_not_exists "Log file removed after cleanup" "$LOG_FILE"
assert_not_exists "Log dir removed when empty" "$LOG_DIR"

report_results
