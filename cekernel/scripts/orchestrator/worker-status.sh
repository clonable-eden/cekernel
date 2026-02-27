#!/usr/bin/env bash
# worker-status.sh — List active Workers
#
# Usage: worker-status.sh
# Output: JSON Lines (1 line = 1 Worker)
#   {"issue": 4, "worktree": "...", "fifo": "...", "uptime": "12m", "state": "RUNNING", "state_detail": "phase1:implement"}
#
# Exit codes:
#   0 — Success
#   1 — Session not initialized
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"

if [[ ! -d "$CEKERNEL_IPC_DIR" ]]; then
  echo "No active session: ${CEKERNEL_IPC_DIR}" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# Collect Worker info from FIFO list
find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | sort | while read -r fifo; do
  basename_fifo=$(basename "$fifo")
  issue="${basename_fifo#worker-}"

  # Look up worktree path
  worktree=""
  if [[ -n "$REPO_ROOT" ]]; then
    # Find worktree matching issue number
    worktree=$(git worktree list --porcelain 2>/dev/null \
      | grep '^worktree ' \
      | sed 's/^worktree //' \
      | grep "/issue/${issue}-" \
      | head -1 || true)
  fi

  # Elapsed time since FIFO creation
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

  # Read worker state
  state_json=$(worker_state_read "$issue")
  worker_state=$(echo "$state_json" | jq -r '.state')
  worker_state_detail=$(echo "$state_json" | jq -r '.detail')

  # JSON output
  jq -cn \
    --argjson issue "$issue" \
    --arg worktree "$worktree" \
    --arg fifo "$fifo" \
    --arg uptime "$uptime" \
    --arg state "$worker_state" \
    --arg state_detail "$worker_state_detail" \
    '{issue: $issue, worktree: $worktree, fifo: $fifo, uptime: $uptime, state: $state, state_detail: $state_detail}'
done
