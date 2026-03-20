#!/usr/bin/env bash
# notify-complete.sh — Process → Orchestrator completion notification (named pipe)
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

FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"

# ── State: TERMINATED (Completed, cleanup pending) ──
# State is written FIRST so the watcher's state-file fallback can detect completion
# even if the FIFO write below fails or the FIFO is missing.
worker_state_write "$ISSUE_NUMBER" TERMINATED "$RESULT"

# ── Lifecycle event type ──
EVENT="COMPLETE"
[[ "$RESULT" == "failed" ]] && EVENT="FAILED"
[[ "$RESULT" == "cancelled" ]] && EVENT="CANCELLED"

# ── Write JSON message to FIFO ──
# This write unblocks the orchestrator's blocking read (primary fast path).
# If FIFO is missing, log a warning but exit 0 — the state file fallback will
# be detected by watch.sh's polling loop.
if [[ ! -p "$FIFO" ]]; then
  echo "Warning: FIFO not found at $FIFO" >&2
  echo "Orchestrator will detect completion via state file fallback." >&2
  if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
    echo "[${TIMESTAMP}] FIFO_MISSING issue=#${ISSUE_NUMBER} path=${FIFO}" >> "$LOG_FILE"
    echo "[${TIMESTAMP}] ${EVENT} issue=#${ISSUE_NUMBER} result=${RESULT} detail=${DETAIL}" >> "$LOG_FILE"
  fi
  echo "Notified orchestrator (state only): issue #${ISSUE_NUMBER} ${RESULT}" >&2
  exit 0
fi

JSON=$(jq -cn \
  --argjson issue "$ISSUE_NUMBER" \
  --arg result "$RESULT" \
  --arg detail "$DETAIL" \
  --arg timestamp "$TIMESTAMP" \
  '{issue: $issue, result: $result, detail: $detail, timestamp: $timestamp}')

if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
  echo "[${TIMESTAMP}] FIFO_WRITE issue=#${ISSUE_NUMBER} result=${RESULT}" >> "$LOG_FILE"
fi
echo "$JSON" > "$FIFO"

# ── Record lifecycle event in log (after successful FIFO write) ──
if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
  echo "[${TIMESTAMP}] ${EVENT} issue=#${ISSUE_NUMBER} result=${RESULT} detail=${DETAIL}" >> "$LOG_FILE"
fi

# ── Release issue lock (skip for ci-passed — Orchestrator manages lifecycle) ──
if [[ "$RESULT" != "ci-passed" ]]; then
  REPO_ROOT="$(resolve_repo_root 2>/dev/null || echo "")"
  if [[ -n "$REPO_ROOT" ]]; then
    issue_lock_release "$REPO_ROOT" "$ISSUE_NUMBER"
  fi
fi

echo "Notified orchestrator: issue #${ISSUE_NUMBER} ${RESULT}" >&2
