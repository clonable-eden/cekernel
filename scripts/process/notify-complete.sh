#!/usr/bin/env bash
# notify-complete.sh — Process → Orchestrator completion notification (state file)
#
# Usage: notify-complete.sh <issue-number> <result> [detail]
#   result: merged | failed | cancelled | ci-passed | approved | changes-requested
#   detail: PR number (merged/ci-passed), error reason (failed), or signal info (cancelled)
#
# Example:
#   notify-complete.sh 4 merged 42
#   notify-complete.sh 4 failed "CI failed 3 times"
#   notify-complete.sh 4 cancelled "TERM signal received"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/issue-lock.sh"
source "${SCRIPT_DIR}/../shared/resolve-repo-root.sh"

ISSUE_NUMBER="${1:?Usage: notify-complete.sh <issue-number> <result> [detail]}"
RESULT="${2:?Result required: merged | failed | cancelled | ci-passed}"
DETAIL="${3:-}"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"

# ── State: TERMINATED (Completed, cleanup pending) ──
# State is written FIRST so the watcher's state-file polling can detect completion.
worker_state_write "$ISSUE_NUMBER" TERMINATED "${RESULT}:${DETAIL}"

# ── Lifecycle event type ──
EVENT="COMPLETE"
[[ "$RESULT" == "failed" ]] && EVENT="FAILED"
[[ "$RESULT" == "cancelled" ]] && EVENT="CANCELLED"

# ── Record lifecycle event in log ──
if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
  echo "[${TIMESTAMP}] ${EVENT} issue=#${ISSUE_NUMBER} result=${RESULT} detail=${DETAIL}" >> "$LOG_FILE"
fi

# ── Release issue lock ──
# Orchestrator-managed transitions retain the lock for the next lifecycle phase.
# Only terminal results (merged, failed, cancelled) release the lock here.
case "$RESULT" in
  ci-passed|changes-requested|approved)
    # Lock retained — Orchestrator manages the next transition
    ;;
  *)
    REPO_ROOT="$(resolve_repo_root 2>/dev/null || echo "")"
    if [[ -n "$REPO_ROOT" ]]; then
      issue_lock_release "$REPO_ROOT" "$ISSUE_NUMBER"
    fi
    ;;
esac

echo "Notified orchestrator: issue #${ISSUE_NUMBER} ${RESULT}" >&2
