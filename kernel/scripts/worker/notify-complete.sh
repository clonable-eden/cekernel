#!/usr/bin/env bash
# notify-complete.sh — Worker → Orchestrator 完了通知 (named pipe)
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

ISSUE_NUMBER="${1:?Usage: notify-complete.sh <issue-number> <status> [detail]}"
STATUS="${2:?Status required: merged | failed}"
DETAIL="${3:-}"

FIFO="${SESSION_IPC_DIR}/worker-${ISSUE_NUMBER}"

# レガシーフォールバック: セッション FIFO が見つからなければ旧パスを試行
if [[ ! -p "$FIFO" ]]; then
  LEGACY_FIFO="/tmp/glimmer-ipc/worker-${ISSUE_NUMBER}"
  if [[ -p "$LEGACY_FIFO" ]]; then
    echo "Warning: using legacy FIFO path (no session)" >&2
    FIFO="$LEGACY_FIFO"
  else
    echo "Error: FIFO not found at $FIFO" >&2
    echo "Orchestrator may not be listening." >&2
    exit 1
  fi
fi

# JSON メッセージを FIFO に書き込み
# この書き込みが orchestrator のブロッキング読み取りを解放する
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

JSON=$(jq -cn \
  --argjson issue "$ISSUE_NUMBER" \
  --arg status "$STATUS" \
  --arg detail "$DETAIL" \
  --arg timestamp "$TIMESTAMP" \
  '{issue: $issue, status: $status, detail: $detail, timestamp: $timestamp}')
echo "$JSON" > "$FIFO"

# ── ライフサイクルイベントをログに記録 ──
LOG_FILE="${SESSION_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
if [[ -d "${SESSION_IPC_DIR}/logs" ]]; then
  EVENT="COMPLETE"
  [[ "$STATUS" == "failed" ]] && EVENT="FAILED"
  echo "[${TIMESTAMP}] ${EVENT} issue=#${ISSUE_NUMBER} status=${STATUS} detail=${DETAIL}" >> "$LOG_FILE"
fi

echo "Notified orchestrator: issue #${ISSUE_NUMBER} ${STATUS}" >&2
