#!/usr/bin/env bash
# spawn-worker.sh — Worktree 作成 + WezTerm ウィンドウで Worker 起動
#
# Usage: spawn-worker.sh <issue-number> [base-branch]
# Output: FIFO path (stdout last line)
set -euo pipefail

ISSUE_NUMBER="${1:?Usage: spawn-worker.sh <issue-number> [base-branch]}"
BASE_BRANCH="${2:-main}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Issue 情報取得 ──
ISSUE_TITLE=$(gh issue view "$ISSUE_NUMBER" --json title -q '.title')
[[ -n "$ISSUE_TITLE" ]] || { echo "Error: issue #${ISSUE_NUMBER} not found" >&2; exit 1; }

# ── ブランチ名・パス生成 ──
# デフォルトの命名規則。対象リポジトリに独自の命名規則がある場合、
# Worker がリネームしてよい（kernel はブランチ名を強制しない）。
SLUG=$(echo "$ISSUE_TITLE" \
  | sed 's/[^a-zA-Z0-9]/-/g' \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-40)
BRANCH="issue/${ISSUE_NUMBER}-${SLUG}"
WORKTREE_DIR="${REPO_ROOT}/.worktrees"
WORKTREE="${WORKTREE_DIR}/${BRANCH}"

# ── FIFO (named pipe) 作成 ──
FIFO_DIR="/tmp/glimmer-ipc"
mkdir -p "$FIFO_DIR"
FIFO="${FIFO_DIR}/worker-${ISSUE_NUMBER}"
[[ -p "$FIFO" ]] || mkfifo "$FIFO"

# ── Worktree 作成 ──
mkdir -p "$WORKTREE_DIR"
git fetch origin "${BASE_BRANCH}" --quiet
git worktree add -b "$BRANCH" "$WORKTREE" "origin/${BASE_BRANCH}"

echo "worktree: $WORKTREE" >&2
echo "branch:   $BRANCH" >&2

# ── WezTerm ウィンドウ起動 (project_layout 相当) ──
#
#   ┌──────────────┬──────────┐
#   │  Claude Code │ Terminal │
#   │   (60%)      │  (40%)   │
#   ├──────────────┴──────────┤
#   │  git log (25%)          │
#   └─────────────────────────┘

MAIN_PANE=$(wezterm cli spawn --new-window --cwd "$WORKTREE")

# 下部: auto-refresh git log
wezterm cli split-pane \
  --bottom --percent 25 \
  --pane-id "$MAIN_PANE" \
  --cwd "$WORKTREE" \
  -- watch -n3 -t -c "git --no-pager log --oneline --graph --color=always"

# 右側: 汎用ターミナル
wezterm cli split-pane \
  --right --percent 40 \
  --pane-id "$MAIN_PANE" \
  --cwd "$WORKTREE"

# メイン pane で Claude Code 起動
# Worker への初期プロンプト:
# 1. 対象リポジトリの CLAUDE.md を最優先で読む
# 2. ライフサイクル（PR → CI → merge → notify）のみ kernel のプロトコルに従う
# 3. 実装・規約は対象リポジトリに完全に従う
PROMPT="issue #${ISSUE_NUMBER} を解決してください。まず対象リポジトリの CLAUDE.md を読み、その規約に完全に従ってください。ライフサイクルのみ kernel の Worker Protocol に従います: 実装 → PR作成 → CI確認 → merge。完了したら ${CLAUDE_PLUGIN_ROOT}/scripts/notify-complete.sh ${ISSUE_NUMBER} merged <pr-number> を実行してください。"
wezterm cli send-text --pane-id "$MAIN_PANE" -- "claude '${PROMPT}'"
wezterm cli send-text --pane-id "$MAIN_PANE" --no-paste $'\r'

echo "worker spawned: issue #${ISSUE_NUMBER}" >&2

# FIFO パスを返す（orchestrator が読み取りに使う）
echo "$FIFO"
