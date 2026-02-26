#!/usr/bin/env bash
# cleanup-worktree.sh — Worktree + branch + ターミナルウィンドウ削除
#
# Usage: cleanup-worktree.sh [--force] <issue-number>
#
# ターミナルはウィンドウ単位で閉じる（メインペインと同一ウィンドウの全ペインを kill）。
# --force は後方互換のため残しているが、現在は通常モードと同じ動作。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
source "${SCRIPT_DIR}/../shared/terminal-adapter.sh"

# ── オプションパース（後方互換: --force を受け入れるが動作は同一） ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) shift ;;
    *) break ;;
  esac
done

ISSUE_NUMBER="${1:?Usage: cleanup-worktree.sh [--force] <issue-number>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE_DIR="${REPO_ROOT}/.worktrees"

# ── ターミナルウィンドウを閉じる ──
# メインペインが属するウィンドウの全ペインを kill する。
# 全ペインが閉じればウィンドウも自動的に閉じる。
PANE_FILE="${SESSION_IPC_DIR}/pane-${ISSUE_NUMBER}"

if [[ -f "$PANE_FILE" ]]; then
  PANE_ID=$(cat "$PANE_FILE")
  if terminal_available; then
    terminal_kill_window "$PANE_ID"
  fi
  rm -f "$PANE_FILE"
fi

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

# ── Trust 登録解除（worktree 削除前に実行、パスが必要なため） ──
unregister_trust "$WORKTREE"

echo "Removing worktree: $WORKTREE" >&2
git worktree remove --force "$WORKTREE"

# ローカルブランチも削除（remote は gh pr merge --delete-branch で削除済み）
if [[ -n "$BRANCH" && "$BRANCH" != "main" ]]; then
  git branch -D "$BRANCH" 2>/dev/null && echo "Deleted branch: $BRANCH" >&2 || true
fi

# FIFO クリーンアップ（セッションスコープ）
rm -f "${SESSION_IPC_DIR}/worker-${ISSUE_NUMBER}"
# Pane ID ファイルのクリーンアップ
rm -f "${SESSION_IPC_DIR}/pane-${ISSUE_NUMBER}"

# ログファイル クリーンアップ
rm -f "${SESSION_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
# 空の logs ディレクトリを削除
rmdir "${SESSION_IPC_DIR}/logs" 2>/dev/null || true

# 空のセッションディレクトリを削除
rmdir "$SESSION_IPC_DIR" 2>/dev/null || true

echo "Cleanup complete for issue #${ISSUE_NUMBER}" >&2
