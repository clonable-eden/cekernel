#!/usr/bin/env bash
# worker-state-write.sh — Standalone wrapper for worker_state_write
#
# Usage: worker-state-write.sh <issue-number> <state> [detail]
#   state: NEW | READY | RUNNING | WAITING | SUSPENDED | TERMINATED
#
# LLM agents running in zsh can call this standalone command without
# sourcing bash-specific scripts directly (avoids zsh "bad substitution"
# errors from bash-specific syntax).
#
# Example:
#   worker-state-write.sh 42 RUNNING "phase1:implement"
#   worker-state-write.sh 42 WAITING "phase3:ci-waiting"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"

ISSUE_NUMBER="${1:?Usage: worker-state-write.sh <issue-number> <state> [detail]}"
STATE="${2:?State required: NEW|READY|RUNNING|WAITING|SUSPENDED|TERMINATED}"
DETAIL="${3:-}"

worker_state_write "$ISSUE_NUMBER" "$STATE" "$DETAIL"
