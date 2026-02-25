#!/usr/bin/env bash
# spawn-worker.sh — Worktree 作成 + WezTerm ウィンドウで Worker 起動
#
# Usage: spawn-worker.sh <issue-number> [base-branch]
# Output: FIFO path (stdout last line)
# Exit codes:
#   0 — Worker 起動成功
#   1 — 一般エラー
#   2 — 同時実行数上限到達 (KERNEL_MAX_WORKERS)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
source "${SCRIPT_DIR}/../shared/resolve-workspace.sh"

ISSUE_NUMBER="${1:?Usage: spawn-worker.sh <issue-number> [base-branch]}"
BASE_BRANCH="${2:-main}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Concurrency Guard ──
MAX_WORKERS="${KERNEL_MAX_WORKERS:-3}"

active_worker_count() {
  find "$SESSION_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | wc -l | tr -d ' '
}

mkdir -p "$SESSION_IPC_DIR"
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_WORKERS" ]]; then
  echo "Error: max workers ($MAX_WORKERS) reached (active: $ACTIVE). Waiting..." >&2
  exit 2
fi

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

# ── Rollback: 途中失敗時のリソースクリーンアップ ──
rollback() {
  echo "Error: spawn-worker.sh failed. Rolling back..." >&2
  # WezTerm pane を kill
  if [[ -n "${MAIN_PANE:-}" ]]; then
    wezterm cli kill-pane --pane-id "$MAIN_PANE" 2>/dev/null || true
  fi
  rm -f "${SESSION_IPC_DIR}/pane-${ISSUE_NUMBER}"
  # Trust 登録解除
  if [[ -n "${WORKTREE:-}" && -d "${WORKTREE:-}" ]]; then
    unregister_trust "$WORKTREE" 2>/dev/null || true
  fi
  # Worktree 削除
  if [[ -n "${WORKTREE:-}" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || true
  fi
  # ブランチ削除
  if [[ -n "${BRANCH:-}" ]]; then
    git branch -D "$BRANCH" 2>/dev/null || true
  fi
  # ログファイル削除
  rm -f "${LOG_FILE:-}"
  rmdir "${LOG_DIR:-}" 2>/dev/null || true
  # FIFO 削除
  rm -f "${FIFO:-}"
}
trap rollback ERR

# ── FIFO (named pipe) 作成 ──
mkdir -p "$SESSION_IPC_DIR"
FIFO="${SESSION_IPC_DIR}/worker-${ISSUE_NUMBER}"
[[ -p "$FIFO" ]] || mkfifo "$FIFO"

# ── ログファイル作成 ──
LOG_DIR="${SESSION_IPC_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/worker-${ISSUE_NUMBER}.log"

# ── Stale worktree/branch cleanup (retry safety) ──
# 前回の spawn 失敗 + 不完全な rollback で worktree や branch が残っている場合、
# 再作成前にクリーンアップする。
cleanup_stale_worktree() {
  local worktree="$1" branch="$2"
  # git worktree として登録されている場合（.git ファイルが worktree 参照を持つ）
  if [[ -f "${worktree}/.git" ]]; then
    echo "Warning: stale worktree found at ${worktree}, removing..." >&2
    git worktree remove --force "$worktree" 2>/dev/null || true
  fi
  # git worktree list に登録されていないが、ディレクトリだけ残っている場合
  if [[ -d "$worktree" ]]; then
    echo "Warning: orphaned worktree directory found at ${worktree}, removing..." >&2
    rm -rf "$worktree"
    git worktree prune 2>/dev/null || true
  fi
  # stale branch を削除
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "Warning: stale branch found: ${branch}, deleting..." >&2
    git branch -D "$branch" 2>/dev/null || true
  fi
}

# ── Worktree 作成 ──
mkdir -p "$WORKTREE_DIR"
git fetch origin "${BASE_BRANCH}" --quiet
cleanup_stale_worktree "$WORKTREE" "$BRANCH"
git worktree add -b "$BRANCH" "$WORKTREE" "origin/${BASE_BRANCH}"

# ── Trust 登録（Worker が trust プロンプトなしで起動できるように） ──
register_trust "$WORKTREE"

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

# Worker に SESSION_ID を伝播
# Orchestrator と同じ workspace に Worker を作成
WORKSPACE=$(resolve_workspace)
WORKSPACE_ARGS=()
if [[ -n "$WORKSPACE" ]]; then
  WORKSPACE_ARGS=(--workspace "$WORKSPACE")
fi
MAIN_PANE=$(wezterm cli spawn --new-window "${WORKSPACE_ARGS[@]}" --cwd "$WORKTREE")

# Pane ID を保存（health-check / cleanup --force で使用）
echo "$MAIN_PANE" > "${SESSION_IPC_DIR}/pane-${ISSUE_NUMBER}"
# WezTerm の --cwd が確実に反映されないケースに備え、明示的に cd する
wezterm cli send-text --pane-id "$MAIN_PANE" -- "cd '${WORKTREE}' && export SESSION_ID='${SESSION_ID}'"
wezterm cli send-text --pane-id "$MAIN_PANE" --no-paste $'\r'

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
PROMPT="issue #${ISSUE_NUMBER} を解決してください。まず対象リポジトリの CLAUDE.md を読み、その規約に完全に従ってください。ライフサイクルのみ kernel の Worker Protocol に従います: 実装 → PR作成 → CI確認 → merge。完了したら ${CLAUDE_PLUGIN_ROOT}/scripts/worker/notify-complete.sh ${ISSUE_NUMBER} merged <pr-number> を実行してください。"
wezterm cli send-text --pane-id "$MAIN_PANE" -- "claude --agent kernel:worker '${PROMPT}'"
wezterm cli send-text --pane-id "$MAIN_PANE" --no-paste $'\r'

# ── ライフサイクルイベントをログに記録 ──
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SPAWN issue=#${ISSUE_NUMBER} branch=${BRANCH}" >> "$LOG_FILE"

echo "session: $SESSION_ID" >&2
echo "worker spawned: issue #${ISSUE_NUMBER}" >&2

# FIFO パスを返す（orchestrator が読み取りに使う）
echo "$FIFO"
