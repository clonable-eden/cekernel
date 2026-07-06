#!/usr/bin/env bash
# cleanup-worktree.sh — Remove worktree + branch + kill Worker
#
# Usage: cleanup-worktree.sh [--force] <issue-number>
#
# Kills the Worker via backend (kills all panes in window for terminal backends,
# or kills process group for headless backend).
#
# CEKERNEL_KEEP_WORKTREE=true preserves the worktree and local branch while
# still killing the Worker and cleaning IPC resources (FIFOs are removed so
# concurrency slots do not leak). --force always removes the worktree,
# ignoring CEKERNEL_KEEP_WORKTREE (zombie recovery must free the worktree).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
source "${SCRIPT_DIR}/../shared/backend-adapter.sh"
source "${SCRIPT_DIR}/../shared/resolve-repo-root.sh"

# ── Option parse ──
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    *) break ;;
  esac
done

# --force always removes the worktree regardless of CEKERNEL_KEEP_WORKTREE
KEEP_WORKTREE="${CEKERNEL_KEEP_WORKTREE:-false}"
[[ "$FORCE" == "1" ]] && KEEP_WORKTREE=false

ISSUE_NUMBER="${1:?Usage: cleanup-worktree.sh [--force] <issue-number>}"
REPO_ROOT="$(resolve_repo_root)"
WORKTREE_DIR="${REPO_ROOT}/.worktrees"

# ── Kill all processes via backend (Worker + Reviewer) ──
# Backend reads handle files internally and kills the processes.
if backend_available; then
  backend_kill_worker "$ISSUE_NUMBER" 2>/dev/null || true
fi
rm -f "${CEKERNEL_IPC_DIR}"/handle-"${ISSUE_NUMBER}".*

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

if [[ "$KEEP_WORKTREE" == "true" ]]; then
  echo "Keeping worktree (CEKERNEL_KEEP_WORKTREE=true): $WORKTREE" >&2
else
  # ── Unregister trust (before worktree removal, since path is needed) ──
  unregister_trust "$WORKTREE"

  echo "Removing worktree: $WORKTREE" >&2
  git worktree remove --force "$WORKTREE"

  # Delete local branch (remote already deleted by gh pr merge --delete-branch)
  if [[ -n "$BRANCH" && "$BRANCH" != "main" ]]; then
    git branch -D "$BRANCH" >/dev/null 2>&1 && echo "Deleted branch: $BRANCH" >&2 || true
  fi
fi

# FIFO cleanup (session-scoped)
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
# State file cleanup
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.state"
# Type file cleanup
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.type"
# Signal file cleanup
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.signal"
# Handle file cleanup (in case not already removed)
rm -f "${CEKERNEL_IPC_DIR}"/handle-"${ISSUE_NUMBER}".*
# Backend file cleanup
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.backend"
# Priority file cleanup
rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.priority"
# Payload file cleanup (wezterm backend: avoids send-text 1024-byte limit)
rm -f "${CEKERNEL_IPC_DIR}/payload-${ISSUE_NUMBER}.b64"

# Log file cleanup
rm -f "${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
# Remove empty logs directory
rmdir "${CEKERNEL_IPC_DIR}/logs" 2>/dev/null || true

# Remove empty session directory
rmdir "$CEKERNEL_IPC_DIR" 2>/dev/null || true

echo "Cleanup complete for issue #${ISSUE_NUMBER}" >&2
