#!/usr/bin/env bash
# test-notify-complete-lock.sh — ci-passed retains issue lock; other results release it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: notify-complete issue lock control by result"

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

# ── Table-driven tests ──
# Format: result:detail:expect_locked (1=lock retained, 0=lock released)
# Lock retention policy:
#   ci-passed, changes-requested, approved → Orchestrator-managed transitions, lock retained
#   merged, failed, cancelled → terminal lifecycle events, lock released
TEST_CASES=(
  "ci-passed:42:1"
  "changes-requested:55:1"
  "approved:55:1"
  "merged:99:0"
  "failed:CI failed:0"
  "cancelled:TERM signal:0"
)

ISSUE_BASE=70
for test_case in "${TEST_CASES[@]}"; do
  IFS=: read -r RESULT DETAIL EXPECT_LOCKED <<< "$test_case"
  ISSUE=$ISSUE_BASE
  ISSUE_BASE=$((ISSUE_BASE + 1))

  issue_lock_acquire "$TEMP_REPO" "$ISSUE"
  setup_fifo "$ISSUE"
  bash -c "cd '$TEMP_REPO' && bash '${CEKERNEL_DIR}/scripts/process/notify-complete.sh' '$ISSUE' '$RESULT' '$DETAIL'" 2>/dev/null || true

  LOCK_CHECK=0
  issue_lock_check "$TEMP_REPO" "$ISSUE" || LOCK_CHECK=$?

  if [[ "$EXPECT_LOCKED" -eq 1 ]]; then
    assert_eq "${RESULT} retains lock" "0" "$LOCK_CHECK"
    issue_lock_release "$TEMP_REPO" "$ISSUE"
  else
    assert_eq "${RESULT} releases lock" "1" "$LOCK_CHECK"
  fi
done

# Cleanup
rm -rf "$CEKERNEL_IPC_DIR"
rm -rf "$TEMP_REPO"
wait 2>/dev/null || true

report_results
