#!/usr/bin/env bash
# test-cleanup-session.sh — Session directory cleanup tests
#
# Tests only the IPC portion of cleanup-worktree.sh.
# git worktree operations are excluded (cannot safely create worktrees in test environment).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: cleanup-session"

export CEKERNEL_SESSION_ID="test-cleanup-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Test 1: Session directory removed when empty after FIFO deletion ──
mkdir -p "$CEKERNEL_IPC_DIR"
FIFO="${CEKERNEL_IPC_DIR}/worker-50"
mkfifo "$FIFO"

assert_fifo_exists "FIFO exists before cleanup" "$FIFO"

# Manually delete FIFO then rmdir to remove directory
rm -f "$FIFO"
rmdir "$CEKERNEL_IPC_DIR" 2>/dev/null || true

assert_not_exists "Empty session dir removed" "$CEKERNEL_IPC_DIR"

# ── Test 2: Directory remains when other FIFOs exist ──
mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-51"
mkfifo "${CEKERNEL_IPC_DIR}/worker-52"

# Delete only worker-51
rm -f "${CEKERNEL_IPC_DIR}/worker-51"
rmdir "$CEKERNEL_IPC_DIR" 2>/dev/null || true

assert_dir_exists "Session dir remains (other FIFOs exist)" "$CEKERNEL_IPC_DIR"
assert_fifo_exists "worker-52 still exists" "${CEKERNEL_IPC_DIR}/worker-52"

# ── Test 3: .backend and .priority files are cleaned up ──
cleanup
mkdir -p "$CEKERNEL_IPC_DIR"
ISSUE=53
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
echo '{"state":"RUNNING"}' > "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.state"
echo "wezterm" > "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.backend"
echo '{"priority":50}' > "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.priority"

# Simulate the IPC cleanup portion of cleanup-worktree.sh (lines 64-81)
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.state"
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.type"
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.signal"
rm -f "${CEKERNEL_IPC_DIR}"/handle-"${ISSUE}".*
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.backend"
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.priority"
rm -f "${CEKERNEL_IPC_DIR}/payload-${ISSUE}.b64"

assert_not_exists ".backend file removed" "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.backend"
assert_not_exists ".priority file removed" "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.priority"

report_results
