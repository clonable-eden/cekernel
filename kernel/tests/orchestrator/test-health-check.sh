#!/usr/bin/env bash
# test-health-check.sh — ゾンビ Worker 検知テスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: health-check"

export SESSION_ID="test-health-00000001"
source "${KERNEL_DIR}/scripts/shared/session-id.sh"

cleanup() {
  rm -rf "$SESSION_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$SESSION_IPC_DIR"

# ── Test 1: FIFO なし → completed ──
RESULT=$(bash "${KERNEL_DIR}/scripts/orchestrator/health-check.sh" 70 2>/dev/null)
assert_match "No FIFO reports completed" '"status":"completed"' "$RESULT"

# ── Test 2: FIFO あり、pane なし、worktree なし → zombie ──
mkfifo "${SESSION_IPC_DIR}/worker-71"
RESULT=$(bash "${KERNEL_DIR}/scripts/orchestrator/health-check.sh" 71 2>/dev/null || true)
assert_match "Orphaned FIFO reports zombie" '"status":"zombie"' "$RESULT"
assert_match "Zombie detail mentions no worktree" 'No worktree found' "$RESULT"

# ── Test 3: 引数なしで全 Worker を検査 ──
mkfifo "${SESSION_IPC_DIR}/worker-72"
RESULT=$(bash "${KERNEL_DIR}/scripts/orchestrator/health-check.sh" 2>/dev/null || true)
assert_match "Issue 71 found in scan" '"issue":71' "$RESULT"
assert_match "Issue 72 found in scan" '"issue":72' "$RESULT"

# ── Test 4: FIFO がないセッションでは正常終了 ──
rm -f "${SESSION_IPC_DIR}/worker-71" "${SESSION_IPC_DIR}/worker-72"
EXIT_CODE=0
bash "${KERNEL_DIR}/scripts/orchestrator/health-check.sh" 2>/dev/null || EXIT_CODE=$?
assert_eq "No workers returns exit 0" "0" "$EXIT_CODE"

report_results
