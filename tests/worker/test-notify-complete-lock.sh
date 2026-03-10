#!/usr/bin/env bash
# test-notify-complete-lock.sh — ci-passed retains issue lock; other statuses release it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: notify-complete issue lock control by status"

# Test session
export CEKERNEL_SESSION_ID="test-notify-lock-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"

# Use a temporary git repo so git rev-parse --show-toplevel works
TEMP_REPO=$(mktemp -d)
# Resolve symlinks (macOS /var -> /private/var) so path matches git rev-parse --show-toplevel
TEMP_REPO=$(cd "$TEMP_REPO" && pwd -P)
git -C "$TEMP_REPO" init -q

mkdir -p "$CEKERNEL_IPC_DIR/logs"

# Helper: create FIFO and start background reader so notify-complete.sh doesn't block
setup_fifo() {
  local issue="$1"
  local fifo="${CEKERNEL_IPC_DIR}/worker-${issue}"
  mkfifo "$fifo"
  cat "$fifo" > /dev/null &
}

# ── Test 1: ci-passed retains lock ──
ISSUE=70
issue_lock_acquire "$TEMP_REPO" "$ISSUE"
# Verify lock exists before running
issue_lock_check "$TEMP_REPO" "$ISSUE"
assert_eq "lock exists before ci-passed" "0" "$?"

setup_fifo "$ISSUE"
bash -c "cd '$TEMP_REPO' && bash '${CEKERNEL_DIR}/scripts/worker/notify-complete.sh' '$ISSUE' ci-passed 42" 2>/dev/null || true

LOCK_CHECK=0
issue_lock_check "$TEMP_REPO" "$ISSUE" || LOCK_CHECK=$?
assert_eq "ci-passed retains lock" "0" "$LOCK_CHECK"

# Cleanup lock for next test
issue_lock_release "$TEMP_REPO" "$ISSUE"

# ── Test 2: merged releases lock ──
ISSUE=71
issue_lock_acquire "$TEMP_REPO" "$ISSUE"

setup_fifo "$ISSUE"
bash -c "cd '$TEMP_REPO' && bash '${CEKERNEL_DIR}/scripts/worker/notify-complete.sh' '$ISSUE' merged 99" 2>/dev/null || true

LOCK_CHECK=0
issue_lock_check "$TEMP_REPO" "$ISSUE" || LOCK_CHECK=$?
assert_eq "merged releases lock" "1" "$LOCK_CHECK"

# ── Test 3: failed releases lock ──
ISSUE=72
issue_lock_acquire "$TEMP_REPO" "$ISSUE"

setup_fifo "$ISSUE"
bash -c "cd '$TEMP_REPO' && bash '${CEKERNEL_DIR}/scripts/worker/notify-complete.sh' '$ISSUE' failed 'CI failed'" 2>/dev/null || true

LOCK_CHECK=0
issue_lock_check "$TEMP_REPO" "$ISSUE" || LOCK_CHECK=$?
assert_eq "failed releases lock" "1" "$LOCK_CHECK"

# ── Test 4: cancelled releases lock ──
ISSUE=73
issue_lock_acquire "$TEMP_REPO" "$ISSUE"

setup_fifo "$ISSUE"
bash -c "cd '$TEMP_REPO' && bash '${CEKERNEL_DIR}/scripts/worker/notify-complete.sh' '$ISSUE' cancelled 'TERM signal'" 2>/dev/null || true

LOCK_CHECK=0
issue_lock_check "$TEMP_REPO" "$ISSUE" || LOCK_CHECK=$?
assert_eq "cancelled releases lock" "1" "$LOCK_CHECK"

# Cleanup
rm -rf "$CEKERNEL_IPC_DIR"
rm -rf "$TEMP_REPO"
wait 2>/dev/null || true

report_results
