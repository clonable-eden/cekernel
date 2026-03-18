#!/usr/bin/env bash
# process-status.sh — List active processes (Workers and Reviewers)
#
# Usage: process-status.sh
# Output: JSON Lines (1 line = 1 process)
#   {"issue": 4, "type": "worker", "worktree": "...", "fifo": "...", "uptime": "12m", "state": "RUNNING", "state_detail": "phase1:implement", "priority": 10, "priority_name": "normal"}
#
# Exit codes:
#   0 — Success
#   1 — Session not initialized
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/worker-priority.sh"

if [[ ! -d "$CEKERNEL_IPC_DIR" ]]; then
  echo "No active session: ${CEKERNEL_IPC_DIR}" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# Collect process info from FIFO list
find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | sort | while read -r fifo; do
  basename_fifo=$(basename "$fifo")
  issue="${basename_fifo#worker-}"

  # Read process type from .type file
  type_file="${CEKERNEL_IPC_DIR}/worker-${issue}.type"
  if [[ -f "$type_file" ]]; then
    process_type=$(tr -d '[:space:]' < "$type_file")
  else
    process_type="unknown"
  fi

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

  # Elapsed time from .spawned file (backward compat: empty file falls back to now)
  spawned_file="${CEKERNEL_IPC_DIR}/${process_type}-${issue}.spawned"
  spawned_at=$(cat "$spawned_file" 2>/dev/null || true)
  spawned_at="${spawned_at:-$(date +%s)}"
  now=$(date +%s)
  elapsed=$((now - spawned_at))
  if [[ $elapsed -ge 3600 ]]; then
    uptime="$((elapsed / 3600))h$((elapsed % 3600 / 60))m"
  elif [[ $elapsed -ge 60 ]]; then
    uptime="$((elapsed / 60))m"
  else
    uptime="${elapsed}s"
  fi

  # Read worker state
  state_json=$(worker_state_read "$issue")
  worker_state=$(echo "$state_json" | jq -r '.state')
  worker_state_detail=$(echo "$state_json" | jq -r '.detail')

  # Read worker priority
  priority_json=$(worker_priority_read "$issue")
  worker_priority=$(echo "$priority_json" | jq -r '.priority')
  worker_priority_name=$(echo "$priority_json" | jq -r '.priority_name')

  # JSON output
  jq -cn \
    --argjson issue "$issue" \
    --arg type "$process_type" \
    --arg worktree "$worktree" \
    --arg fifo "$fifo" \
    --arg uptime "$uptime" \
    --arg state "$worker_state" \
    --arg state_detail "$worker_state_detail" \
    --argjson priority "$worker_priority" \
    --arg priority_name "$worker_priority_name" \
    '{issue: $issue, type: $type, worktree: $worktree, fifo: $fifo, uptime: $uptime, state: $state, state_detail: $state_detail, priority: $priority, priority_name: $priority_name}'
done
