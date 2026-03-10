#!/usr/bin/env bash
# notify-complete.sh — Worker → Orchestrator completion notification (named pipe)
#
# Usage: notify-complete.sh <issue-number> <status> [detail]
#   status: merged | failed | cancelled | ci-passed
#   detail: PR number (merged), error reason (failed), or signal info (cancelled)
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

ISSUE_NUMBER="${1:?Usage: notify-complete.sh <issue-number> <status> [detail]}"
STATUS="${2:?Status required: merged | failed | cancelled}"
DETAIL="${3:-}"

FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"

# ── State: TERMINATED (Completed, cleanup pending) ──
# State is written FIRST so the watcher's state-file fallback can detect completion
# even if the FIFO write below fails or the FIFO is missing.
worker_state_write "$ISSUE_NUMBER" TERMINATED "$STATUS"

# ── Lifecycle event type ──
EVENT="COMPLETE"
[[ "$STATUS" == "failed" ]] && EVENT="FAILED"
[[ "$STATUS" == "cancelled" ]] && EVENT="CANCELLED"

# ── Write JSON message to FIFO ──
# This write unblocks the orchestrator's blocking read (primary fast path).
# If FIFO is missing, log a warning but exit 0 — the state file fallback will
# be detected by watch-worker.sh's polling loop.
if [[ ! -p "$FIFO" ]]; then
  echo "Warning: FIFO not found at $FIFO" >&2
  echo "Orchestrator will detect completion via state file fallback." >&2
  if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
    echo "[${TIMESTAMP}] FIFO_MISSING issue=#${ISSUE_NUMBER} path=${FIFO}" >> "$LOG_FILE"
    echo "[${TIMESTAMP}] ${EVENT} issue=#${ISSUE_NUMBER} status=${STATUS} detail=${DETAIL}" >> "$LOG_FILE"
  fi
  echo "Notified orchestrator (state only): issue #${ISSUE_NUMBER} ${STATUS}" >&2
  exit 0
fi

JSON=$(jq -cn \
  --argjson issue "$ISSUE_NUMBER" \
  --arg status "$STATUS" \
  --arg detail "$DETAIL" \
  --arg timestamp "$TIMESTAMP" \
  '{issue: $issue, status: $status, detail: $detail, timestamp: $timestamp}')

if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
  echo "[${TIMESTAMP}] FIFO_WRITE issue=#${ISSUE_NUMBER} status=${STATUS}" >> "$LOG_FILE"
fi
echo "$JSON" > "$FIFO"

# ── Record lifecycle event in log (after successful FIFO write) ──
if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
  echo "[${TIMESTAMP}] ${EVENT} issue=#${ISSUE_NUMBER} status=${STATUS} detail=${DETAIL}" >> "$LOG_FILE"
fi

# ── Release issue lock (skip for ci-passed — Orchestrator manages lifecycle) ──
if [[ "$STATUS" != "ci-passed" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [[ -n "$REPO_ROOT" ]]; then
    issue_lock_release "$REPO_ROOT" "$ISSUE_NUMBER"
  fi
fi

echo "Notified orchestrator: issue #${ISSUE_NUMBER} ${STATUS}" >&2
