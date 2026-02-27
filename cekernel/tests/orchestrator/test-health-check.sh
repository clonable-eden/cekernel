#!/usr/bin/env bash
# test-health-check.sh — Zombie Worker detection tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: health-check"

export CEKERNEL_SESSION_ID="test-health-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$CEKERNEL_IPC_DIR"

# Use wezterm backend for tests (default)
export CEKERNEL_BACKEND=wezterm

# ── Test 1: No FIFO → completed ──
RESULT=$(bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 70 2>/dev/null)
assert_match "No FIFO reports completed" '"status":"completed"' "$RESULT"

# ── Test 2: FIFO exists, no handle, no worktree → zombie ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-71"
RESULT=$(bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 71 2>/dev/null || true)
assert_match "Orphaned FIFO reports zombie" '"status":"zombie"' "$RESULT"
assert_match "Zombie detail mentions worker dead" 'worker dead' "$RESULT"

# ── Test 3: No arguments → inspect all workers ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-72"
RESULT=$(bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 2>/dev/null || true)
assert_match "Issue 71 found in scan" '"issue":71' "$RESULT"
assert_match "Issue 72 found in scan" '"issue":72' "$RESULT"

# ── Test 4: No FIFOs in session → exit 0 ──
rm -f "${CEKERNEL_IPC_DIR}/worker-71" "${CEKERNEL_IPC_DIR}/worker-72"
EXIT_CODE=0
bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 2>/dev/null || EXIT_CODE=$?
assert_eq "No workers returns exit 0" "0" "$EXIT_CODE"

report_results
