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

ISSUE_NUMBER="${1:?Usage: notify-complete.sh <issue-number> <status> [detail]}"
STATUS="${2:?Status required: merged | failed}"
DETAIL="${3:-}"

FIFO="/tmp/glimmer-ipc/worker-${ISSUE_NUMBER}"

if [[ ! -p "$FIFO" ]]; then
  echo "Error: FIFO not found at $FIFO" >&2
  echo "Orchestrator may not be listening." >&2
  exit 1
fi

# JSON メッセージを FIFO に書き込み
# この書き込みが orchestrator のブロッキング読み取りを解放する
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$FIFO" <<EOF
{"issue":${ISSUE_NUMBER},"status":"${STATUS}","detail":"${DETAIL}","timestamp":"${TIMESTAMP}"}
EOF

echo "Notified orchestrator: issue #${ISSUE_NUMBER} ${STATUS}" >&2
