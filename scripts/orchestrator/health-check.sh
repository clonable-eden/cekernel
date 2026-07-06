#!/usr/bin/env bash
# health-check.sh — Detect and report zombie Workers
#
# Usage: health-check.sh [issue-number...]
#   Without issue numbers: inspect all Workers in the session
#
# Zombie = FIFO exists but the Worker process is dead
# (waitpid + WNOHANG equivalent)
# Blocked = Worker session is waiting on a permission dialog (ADR-0016;
# headless backend only — surfaced distinctly, counts as unhealthy)
#
# Exit code:
#   0 — all workers healthy (or no workers found)
#   1 — unhealthy workers detected (zombie or blocked)
#
# Output (stdout): JSON Lines with worker status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/backend-adapter.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"

# If issue numbers are specified, inspect only those. Otherwise inspect all FIFOs in session
if [[ $# -gt 0 ]]; then
  ISSUES=("$@")
else
  ISSUES=()
  if [[ -d "$CEKERNEL_IPC_DIR" ]]; then
    for fifo in "${CEKERNEL_IPC_DIR}"/worker-*; do
      [[ -p "$fifo" ]] || continue
      issue=$(basename "$fifo" | sed 's/^worker-//')
      ISSUES+=("$issue")
    done
  fi
fi

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  echo "No active workers found in session ${CEKERNEL_SESSION_ID}" >&2
  exit 0
fi

UNHEALTHY=0

check_worker() {
  local issue="$1"
  local fifo="${CEKERNEL_IPC_DIR}/worker-${issue}"
  local status="unknown"
  local detail=""

  # No active FIFO means completed
  if [[ ! -p "$fifo" ]]; then
    echo "{\"issue\":${issue},\"status\":\"completed\",\"detail\":\"No active FIFO\"}"
    return 0
  fi

  # 1. Backend liveness check (handle file managed by backend)
  if backend_available; then
    if backend_worker_alive "$issue"; then
      status="healthy"
      detail="worker alive"
      # blocked = alive but stalled on a permission dialog — surface it
      # distinctly when the backend provides a status (ADR-0016)
      if declare -F backend_worker_status >/dev/null 2>&1; then
        local wstatus
        wstatus=$(backend_worker_status "$issue" 2>/dev/null) || wstatus=""
        if [[ "$wstatus" == "blocked" ]]; then
          status="blocked"
          detail="session waiting on a permission dialog"
        fi
      fi
    else
      status="zombie"
      detail="worker dead"
    fi
  fi

  # 2. If backend check was inconclusive, fallback to process-based detection
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

  # Read worker state for richer output
  local state_json worker_state
  state_json=$(worker_state_read "$issue")
  worker_state=$(echo "$state_json" | jq -r '.state')

  jq -cn \
    --argjson issue "$issue" \
    --arg status "$status" \
    --arg detail "$detail" \
    --arg state "$worker_state" \
    '{issue: $issue, status: $status, detail: $detail, state: $state}'

  if [[ "$status" == "zombie" || "$status" == "blocked" ]]; then
    return 1
  fi
  return 0
}

for issue in "${ISSUES[@]}"; do
  if ! check_worker "$issue"; then
    UNHEALTHY=$((UNHEALTHY + 1))
  fi
done

echo "---" >&2
echo "Health check: ${#ISSUES[@]} workers, ${UNHEALTHY} unhealthy (zombie/blocked)." >&2

if [[ "$UNHEALTHY" -gt 0 ]]; then
  exit 1
fi

exit 0
