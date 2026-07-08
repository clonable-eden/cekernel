#!/usr/bin/env bash
# health-check.sh — Detect and report zombie Workers
#
# Usage: health-check.sh [issue-number...]
#   Without issue numbers: inspect all Workers in the session
#
# ADR-0020 Phase 2: zombie = non-TERMINATED state + dead backend verdict
# (the held slot that orchctl recover resolves).
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

# If issue numbers are specified, inspect only those.
# Otherwise inspect all non-TERMINATED workers in session (ADR-0020 Phase 2).
if [[ $# -gt 0 ]]; then
  # Filter explicitly-specified issues: skip TERMINATED ones
  ISSUES=()
  for _arg_issue in "$@"; do
    _state_json=$(worker_state_read "$_arg_issue")
    _state=$(echo "$_state_json" | jq -r '.state')
    if [[ "$_state" != "TERMINATED" ]]; then
      ISSUES+=("$_arg_issue")
    fi
  done
else
  ISSUES=()
  if [[ -d "$CEKERNEL_IPC_DIR" ]]; then
    for _active_issue in $(worker_state_list_active "$CEKERNEL_IPC_DIR"); do
      ISSUES+=("$_active_issue")
    done
  fi
fi

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  echo "No active workers found in session ${CEKERNEL_SESSION_ID}" >&2
  exit 0
fi

UNHEALTHY=0

# ADR-0020 Phase 2: zombie = non-TERMINATED state + dead backend verdict.
# Only non-TERMINATED workers are inspected (enumeration already filters).
check_worker() {
  local issue="$1"
  local status="unknown"
  local detail=""

  # 1. Backend verdict check (handle file managed by backend, ADR-0018).
  # Degradation policy: query-failed / unknown-value are INCONCLUSIVE —
  # reported as "unknown" without counting the worker unhealthy (a
  # zombie flag triggers recovery; never declare a crash on doubt).
  local backend_conclusive=0
  if backend_available && declare -F backend_worker_status >/dev/null 2>&1; then
    local wstatus
    wstatus=$(backend_worker_status "$issue" 2>/dev/null) || true
    case "$wstatus" in
      alive)
        backend_conclusive=1
        status="healthy"
        detail="worker alive"
        ;;
      blocked)
        # alive but stalled on a permission dialog — surfaced distinctly
        # (ADR-0016 MUST)
        backend_conclusive=1
        status="blocked"
        detail="session waiting on a permission dialog"
        ;;
      query-failed|unknown-value)
        backend_conclusive=1
        status="unknown"
        detail="cannot verify session (${wstatus}) — inconclusive, not treated as zombie"
        ;;
      done|stopped|not-listed|missing)
        backend_conclusive=1
        status="zombie"
        detail="worker dead (verdict: ${wstatus})"
        ;;
    esac
  elif backend_available; then
    # Backend without a status function: boolean liveness only
    if backend_worker_alive "$issue"; then
      backend_conclusive=1
      status="healthy"
      detail="worker alive"
    else
      backend_conclusive=1
      status="zombie"
      detail="worker dead"
    fi
  fi

  # 2. If no backend was available, fallback to process-based detection
  if [[ "$backend_conclusive" -eq 0 ]]; then
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
