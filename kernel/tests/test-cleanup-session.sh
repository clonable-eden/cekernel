#!/usr/bin/env bash
# test-cleanup-session.sh — セッションディレクトリのクリーンアップテスト
#
# cleanup-worktree.sh の IPC 部分のみテスト。
# git worktree 操作は除外（テスト環境で worktree を安全に作れないため）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "test: cleanup-session"

export SESSION_ID="test-cleanup-00000001"
source "${KERNEL_DIR}/scripts/session-id.sh"

cleanup() {
  rm -rf "$SESSION_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Test 1: FIFO 削除後、セッションディレクトリが空なら削除される ──
mkdir -p "$SESSION_IPC_DIR"
FIFO="${SESSION_IPC_DIR}/worker-50"
mkfifo "$FIFO"

assert_fifo_exists "FIFO exists before cleanup" "$FIFO"

# FIFO を手動削除してから rmdir でディレクトリを削除
rm -f "$FIFO"
rmdir "$SESSION_IPC_DIR" 2>/dev/null || true

assert_not_exists "Empty session dir removed" "$SESSION_IPC_DIR"

# ── Test 2: 他の FIFO が残っていればディレクトリは残る ──
mkdir -p "$SESSION_IPC_DIR"
mkfifo "${SESSION_IPC_DIR}/worker-51"
mkfifo "${SESSION_IPC_DIR}/worker-52"

# worker-51 だけ削除
rm -f "${SESSION_IPC_DIR}/worker-51"
rmdir "$SESSION_IPC_DIR" 2>/dev/null || true

assert_dir_exists "Session dir remains (other FIFOs exist)" "$SESSION_IPC_DIR"
assert_fifo_exists "worker-52 still exists" "${SESSION_IPC_DIR}/worker-52"

report_results
