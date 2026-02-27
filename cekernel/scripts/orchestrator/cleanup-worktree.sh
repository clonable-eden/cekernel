#!/usr/bin/env bash
# cleanup-worktree.sh — Remove worktree + branch + terminal window
#
# Usage: cleanup-worktree.sh [--force] <issue-number>
#
# Closes the terminal at window level (kills all panes in the same window as main pane).
# --force is kept for backward compatibility but behaves the same as normal mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
source "${SCRIPT_DIR}/../shared/terminal-adapter.sh"

# ── Option parse (backward compat: accept --force but behavior is identical) ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) shift ;;
    *) break ;;
  esac
done

ISSUE_NUMBER="${1:?Usage: cleanup-worktree.sh [--force] <issue-number>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE_DIR="${REPO_ROOT}/.worktrees"

# ── Close terminal window ──
# Kill all panes in the window that the main pane belongs to.
# When all panes are closed, the window closes automatically.
PANE_FILE="${CEKERNEL_IPC_DIR}/pane-${ISSUE_NUMBER}"

if [[ -f "$PANE_FILE" ]]; then
  PANE_ID=$(cat "$PANE_FILE")
  if terminal_available; then
    terminal_kill_window "$PANE_ID"
  fi
  rm -f "$PANE_FILE"
fi

# Find worktree matching issue number
WORKTREE=$(git worktree list --porcelain \
  | grep -A2 "^worktree " \
  | grep "issue/${ISSUE_NUMBER}-" \
  | head -1 \
  | sed 's/^worktree //')

if [[ -z "$WORKTREE" ]]; then
  # Fallback: search directories directly
  WORKTREE=$(find "$WORKTREE_DIR" -maxdepth 2 -type d -name "issue" -exec find {} -maxdepth 1 -name "${ISSUE_NUMBER}-*" \; 2>/dev/null | head -1)
  [[ -n "$WORKTREE" ]] || { echo "No worktree found for issue #${ISSUE_NUMBER}" >&2; exit 1; }
fi

# Get branch name
BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

# ── Unregister trust (before worktree removal, since path is needed) ──
unregister_trust "$WORKTREE"

echo "Removing worktree: $WORKTREE" >&2
git worktree remove --force "$WORKTREE"

# Delete local branch (remote already deleted by gh pr merge --delete-branch)
if [[ -n "$BRANCH" && "$BRANCH" != "main" ]]; then
  git branch -D "$BRANCH" 2>/dev/null && echo "Deleted branch: $BRANCH" >&2 || true
fi

# FIFO cleanup (session-scoped)
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
# State file cleanup
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.state"
# Pane ID file cleanup
rm -f "${CEKERNEL_IPC_DIR}/pane-${ISSUE_NUMBER}"

# Log file cleanup
rm -f "${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
# Remove empty logs directory
rmdir "${CEKERNEL_IPC_DIR}/logs" 2>/dev/null || true

# Remove empty session directory
rmdir "$CEKERNEL_IPC_DIR" 2>/dev/null || true

echo "Cleanup complete for issue #${ISSUE_NUMBER}" >&2
