#!/usr/bin/env bash
# phase-transition.sh — Atomic phase boundary: signal check + state write
#
# Usage: phase-transition.sh <issue-number> <state> [detail]
#
# Combines check-signal.sh and worker-state-write.sh into a single call
# for use at phase boundaries. This ensures signal checks are never
# forgotten, since Workers reliably call state-write at each boundary.
#
# Flow:
#   1. Check for pending signal (check-signal.sh)
#   2. If signal found → output signal name to stdout, exit 3
#   3. If no signal   → write state (worker-state-write.sh), exit 0
#
# Exit codes:
#   0 — No signal; state written successfully
#   1 — Usage error (missing arguments, invalid state)
#   3 — Signal received (signal name on stdout)
#
# Example:
#   phase-transition.sh 42 RUNNING "phase1:implement"
#   # → checks signal, then writes RUNNING state
#
#   SIGNAL=$(phase-transition.sh 42 RUNNING "phase1:implement") || EXIT=$?
#   if [[ "${EXIT:-0}" -eq 3 ]]; then
#     echo "Signal received: $SIGNAL"
#   fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ISSUE_NUMBER="${1:?Usage: phase-transition.sh <issue-number> <state> [detail]}"
STATE="${2:?State required: NEW|READY|RUNNING|WAITING|SUSPENDED|TERMINATED}"
DETAIL="${3:-}"

# ── Step 1: Check for pending signal ──
SIGNAL=$("${SCRIPT_DIR}/check-signal.sh" "$ISSUE_NUMBER") || true

if [[ -n "$SIGNAL" ]]; then
  echo "$SIGNAL"
  exit 3
fi

# ── Step 2: Write state ──
"${SCRIPT_DIR}/worker-state-write.sh" "$ISSUE_NUMBER" "$STATE" "$DETAIL"
