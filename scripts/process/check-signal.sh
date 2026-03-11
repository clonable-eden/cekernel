#!/usr/bin/env bash
# check-signal.sh — Check for pending signal (process-side)
#
# Usage: check-signal.sh <issue-number>
#
# Checks if a signal file exists for the given issue number.
# If found, outputs the signal name, consumes (deletes) the file, and exits 0.
# If not found, exits 1 (no signal pending).
#
# Example:
#   if SIGNAL=$(check-signal.sh 4); then
#     echo "Received signal: $SIGNAL"
#   fi
#
# Exit codes:
#   0 — Signal found (signal name on stdout)
#   1 — No signal pending
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"

ISSUE_NUMBER="${1:?Usage: check-signal.sh <issue-number>}"

SIGNAL_FILE="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.signal"

# ── Check for signal file ──
if [[ ! -f "$SIGNAL_FILE" ]]; then
  exit 1
fi

# ── Read and consume signal ──
SIGNAL=$(tr -d '[:space:]' < "$SIGNAL_FILE")
rm -f "$SIGNAL_FILE"

# ── Record lifecycle event in log ──
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-${ISSUE_NUMBER}.log"
if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[${TIMESTAMP}] SIGNAL_RECEIVED issue=#${ISSUE_NUMBER} signal=${SIGNAL}" >> "$LOG_FILE"
fi

echo "$SIGNAL"
