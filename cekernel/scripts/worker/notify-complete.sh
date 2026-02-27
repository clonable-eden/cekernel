#!/usr/bin/env bash
# notify-complete.sh — Worker → Orchestrator completion notification (named pipe)
#
# Usage: notify-complete.sh <issue-number> <status> [detail]
#   status: merged | failed
#   detail: PR number (merged) or error reason (failed)
#
# Example:
#   notify-complete.sh 4 merged 42
#   notify-complete.sh 4 failed "CI failed 3 times"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"

ISSUE_NUMBER="${1:?Usage: notify-complete.sh <issue-number> <status> [detail]}"
STATUS="${2:?Status required: merged | failed}"
DETAIL="${3:-}"

FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"

if [[ ! -p "$FIFO" ]]; then
  echo "Error: FIFO not found at $FIFO" >&2
  echo "Orchestrator may not be listening." >&2
  exit 1
fi

# ── State: TERMINATED (Completed, cleanup pending) ──
worker_state_write "$ISSUE_NUMBER" TERMINATED "$STATUS"

# Write JSON message to FIFO
# This write unblocks the orchestrator's blocking read
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

JSON=$(jq -cn \
  --argjson issue "$ISSUE_NUMBER" \
  --arg status "$STATUS" \
  --arg detail "$DETAIL" \
  --arg timestamp "$TIMESTAMP" \
  '{issue: $issue, status: $status, detail: $detail, timestamp: $timestamp}')
echo "$JSON" > "$FIFO"

# ── Record lifecycle event in log ──
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
  EVENT="COMPLETE"
  [[ "$STATUS" == "failed" ]] && EVENT="FAILED"
  echo "[${TIMESTAMP}] ${EVENT} issue=#${ISSUE_NUMBER} status=${STATUS} detail=${DETAIL}" >> "$LOG_FILE"
fi

echo "Notified orchestrator: issue #${ISSUE_NUMBER} ${STATUS}" >&2
