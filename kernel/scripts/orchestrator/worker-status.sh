#!/usr/bin/env bash
# worker-status.sh — 稼働中 Worker の一覧を表示
#
# Usage: worker-status.sh
# Output: JSON Lines (1 行 = 1 Worker)
#   {"issue": 4, "worktree": "/path/to/.worktrees/issue/4-...", "fifo": "/tmp/cekernel-ipc/.../worker-4", "uptime": "12m"}
#
# Exit codes:
#   0 — 正常終了
#   1 — セッション未初期化
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"

if [[ ! -d "$CEKERNEL_IPC_DIR" ]]; then
  echo "No active session: ${CEKERNEL_IPC_DIR}" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# FIFO 一覧から Worker 情報を収集
find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | sort | while read -r fifo; do
  basename_fifo=$(basename "$fifo")
  issue="${basename_fifo#worker-}"

  # worktree パスを探索
  worktree=""
  if [[ -n "$REPO_ROOT" ]]; then
    # issue 番号に一致する worktree を検索
    worktree=$(git worktree list --porcelain 2>/dev/null \
      | grep '^worktree ' \
      | sed 's/^worktree //' \
      | grep "/issue/${issue}-" \
      | head -1 || true)
  fi

  # FIFO の作成時刻からの経過時間
  if stat -f '%m' "$fifo" &>/dev/null; then
    # macOS stat
    created=$(stat -f '%m' "$fifo")
  elif stat -c '%Y' "$fifo" &>/dev/null; then
    # GNU/Linux stat
    created=$(stat -c '%Y' "$fifo")
  else
    created=""
  fi

  uptime=""
  if [[ -n "$created" ]]; then
    now=$(date +%s)
    elapsed=$((now - created))
    if [[ $elapsed -ge 3600 ]]; then
      uptime="$((elapsed / 3600))h$((elapsed % 3600 / 60))m"
    elif [[ $elapsed -ge 60 ]]; then
      uptime="$((elapsed / 60))m"
    else
      uptime="${elapsed}s"
    fi
  fi

  # JSON 出力
  jq -cn \
    --argjson issue "$issue" \
    --arg worktree "$worktree" \
    --arg fifo "$fifo" \
    --arg uptime "$uptime" \
    '{issue: $issue, worktree: $worktree, fifo: $fifo, uptime: $uptime}'
done
