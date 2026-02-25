#!/usr/bin/env bash
# health-check.sh — ゾンビ Worker の検知・報告
#
# Usage: health-check.sh [issue-number...]
#   issue 番号省略時: セッション内の全 Worker を検査
#
# ゾンビ = FIFO が存在するが Worker プロセスが死んでいる状態
# （waitpid + WNOHANG 相当）
#
# Exit code:
#   0 — all workers healthy (or no workers found)
#   1 — zombie workers detected
#
# Output (stdout): JSON Lines with worker status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"

# issue 番号が指定されていれば、それだけ検査。なければセッション内全 FIFO を検査
if [[ $# -gt 0 ]]; then
  ISSUES=("$@")
else
  ISSUES=()
  if [[ -d "$SESSION_IPC_DIR" ]]; then
    for fifo in "${SESSION_IPC_DIR}"/worker-*; do
      [[ -p "$fifo" ]] || continue
      issue=$(basename "$fifo" | sed 's/^worker-//')
      ISSUES+=("$issue")
    done
  fi
fi

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  echo "No active workers found in session ${SESSION_ID}" >&2
  exit 0
fi

ZOMBIES=0

check_worker() {
  local issue="$1"
  local fifo="${SESSION_IPC_DIR}/worker-${issue}"
  local pane_file="${SESSION_IPC_DIR}/pane-${issue}"
  local status="unknown"
  local detail=""

  # FIFO が存在しなければ完了済み
  if [[ ! -p "$fifo" ]]; then
    echo "{\"issue\":${issue},\"status\":\"completed\",\"detail\":\"No active FIFO\"}"
    return 0
  fi

  # 1. WezTerm pane チェック（pane ID ファイルがあれば）
  if [[ -f "$pane_file" ]]; then
    local pane_id
    pane_id=$(cat "$pane_file")
    if command -v wezterm >/dev/null 2>&1; then
      if wezterm cli list --format json 2>/dev/null | grep -q "\"pane_id\":${pane_id}[,}]"; then
        status="healthy"
        detail="WezTerm pane ${pane_id} alive"
      else
        status="zombie"
        detail="WezTerm pane ${pane_id} dead"
      fi
    fi
  fi

  # 2. pane チェックで判定できなかった場合、プロセスベースでフォールバック
  if [[ "$status" == "unknown" ]]; then
    local worktree=""
    worktree=$(git worktree list --porcelain 2>/dev/null \
      | grep "issue/${issue}-" \
      | head -1 \
      | sed 's/^worktree //' || true)

    if [[ -n "$worktree" ]]; then
      if pgrep -f "${worktree}" >/dev/null 2>&1; then
        status="healthy"
        detail="Process found for worktree"
      else
        status="zombie"
        detail="No process found for worktree"
      fi
    else
      status="zombie"
      detail="No worktree found"
    fi
  fi

  echo "{\"issue\":${issue},\"status\":\"${status}\",\"detail\":\"${detail}\"}"

  if [[ "$status" == "zombie" ]]; then
    return 1
  fi
  return 0
}

for issue in "${ISSUES[@]}"; do
  if ! check_worker "$issue"; then
    ZOMBIES=$((ZOMBIES + 1))
  fi
done

echo "---" >&2
echo "Health check: ${#ISSUES[@]} workers, ${ZOMBIES} zombies." >&2

if [[ "$ZOMBIES" -gt 0 ]]; then
  exit 1
fi

exit 0
