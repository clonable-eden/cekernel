#!/usr/bin/env bash
# reviewer-state-write.sh — Standalone wrapper for reviewer_state_write
#
# Usage: reviewer-state-write.sh <issue-number> <state> [detail]
#   state: REVIEWING | TERMINATED
#   detail (TERMINATED): approved | changes-requested | failed
#          Unknown verdicts are rejected with exit 1 (ADR-0021 Amendment 2).
#
# LLM agents running in zsh can call this standalone command without
# sourcing bash-specific scripts directly (avoids zsh "bad substitution"
# errors from bash-specific syntax).
#
# Example:
#   reviewer-state-write.sh 42 REVIEWING "review:in-progress"
#   reviewer-state-write.sh 42 TERMINATED "approved"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/reviewer-state.sh"

ISSUE_NUMBER="${1:?Usage: reviewer-state-write.sh <issue-number> <state> [detail]}"
STATE="${2:?State required: REVIEWING|TERMINATED}"
DETAIL="${3:-}"

reviewer_state_write "$ISSUE_NUMBER" "$STATE" "$DETAIL"
