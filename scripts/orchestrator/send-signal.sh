#!/usr/bin/env bash
# send-signal.sh — Send a signal to a running Worker
#
# Usage: send-signal.sh <issue-number> <signal>
#   signal: TERM, SUSPEND
#
# Creates a signal file in the IPC directory. Worker checks for this file
# at phase boundaries (cooperative signal delivery).
#
# Example:
#   send-signal.sh 4 TERM
#
# Exit codes:
#   0 — Signal sent
#   1 — Error (missing args, unsupported signal, no IPC dir)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"

ISSUE_NUMBER="${1:?Usage: send-signal.sh <issue-number> <signal>}"
SIGNAL="${2:?Usage: send-signal.sh <issue-number> <signal>}"

# ── Validate signal ──
SUPPORTED_SIGNALS="TERM SUSPEND"
VALID=0
for s in $SUPPORTED_SIGNALS; do
  if [[ "$SIGNAL" == "$s" ]]; then
    VALID=1
    break
  fi
done

if [[ "$VALID" -eq 0 ]]; then
  echo "Error: unsupported signal '${SIGNAL}'. Supported: ${SUPPORTED_SIGNALS}" >&2
  exit 1
fi

# ── Validate IPC directory ──
if [[ ! -d "$CEKERNEL_IPC_DIR" ]]; then
  echo "Error: IPC directory not found: ${CEKERNEL_IPC_DIR}" >&2
  exit 1
fi

# ── Write signal file ──
SIGNAL_FILE="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.signal"
echo "$SIGNAL" > "$SIGNAL_FILE"

echo "Signal ${SIGNAL} sent to worker #${ISSUE_NUMBER}" >&2
