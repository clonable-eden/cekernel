#!/usr/bin/env bash
# cleanup-worktree.sh — Worktree + branch 削除
#
# Usage: cleanup-worktree.sh <issue-number>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/session-id.sh"

ISSUE_NUMBER="${1:?Usage: cleanup-worktree.sh <issue-number>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE_DIR="${REPO_ROOT}/.worktrees"

# issue 番号に一致する worktree を検索
WORKTREE=$(git worktree list --porcelain \
  | grep -A2 "^worktree " \
  | grep "issue/${ISSUE_NUMBER}-" \
  | head -1 \
  | sed 's/^worktree //')

if [[ -z "$WORKTREE" ]]; then
  # フォールバック: ディレクトリを直接検索
  WORKTREE=$(find "$WORKTREE_DIR" -maxdepth 2 -type d -name "issue" -exec find {} -maxdepth 1 -name "${ISSUE_NUMBER}-*" \; 2>/dev/null | head -1)
  [[ -n "$WORKTREE" ]] || { echo "No worktree found for issue #${ISSUE_NUMBER}" >&2; exit 1; }
fi

# ブランチ名を取得
BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

echo "Removing worktree: $WORKTREE" >&2
git worktree remove --force "$WORKTREE"

# ローカルブランチも削除（remote は gh pr merge --delete-branch で削除済み）
if [[ -n "$BRANCH" && "$BRANCH" != "main" ]]; then
  git branch -D "$BRANCH" 2>/dev/null && echo "Deleted branch: $BRANCH" >&2 || true
fi

# FIFO クリーンアップ（セッションスコープ）
rm -f "${SESSION_IPC_DIR}/worker-${ISSUE_NUMBER}"
# 空のセッションディレクトリを削除
rmdir "$SESSION_IPC_DIR" 2>/dev/null || true

echo "Cleanup complete for issue #${ISSUE_NUMBER}" >&2
