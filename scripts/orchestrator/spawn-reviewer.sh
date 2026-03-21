#!/usr/bin/env bash
# spawn-reviewer.sh — Spawn a Reviewer process (wrapper for spawn.sh --agent reviewer)
#
# Usage: spawn-reviewer.sh [--priority <priority>] <issue-number> <pr-number>
#   priority: critical|high|normal|low or numeric 0-19 (default: normal)
# Output: FIFO path (stdout last line)
# Options:
#   --priority  Set reviewer priority (nice value)
# Note: Always runs with --resume (reuses Worker's worktree). A Reviewer
#       is only spawned after a Worker has completed ci-passed.
#       State management uses issue-number (consistent with Workers).
#       PR number is passed to the Reviewer via prompt.
# Exit codes:
#   0 — Reviewer spawned successfully
#   1 — General error
#   2 — Max concurrent processes reached (CEKERNEL_MAX_ORCH_CHILDREN)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Flag parsing ──
FLAGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --priority) FLAGS+=(--priority "$2"); shift 2 ;;
    *) break ;;
  esac
done

ISSUE_NUMBER="${1:?Usage: spawn-reviewer.sh [--priority <priority>] <issue-number> <pr-number>}"
PR_NUMBER="${2:?Usage: spawn-reviewer.sh [--priority <priority>] <issue-number> <pr-number>}"

REVIEWER_PROMPT="Review PR #${PR_NUMBER} for issue #${ISSUE_NUMBER}. Read the repository's CLAUDE.md, the issue body (.cekernel-task.md), and the PR diff. Submit your review via gh pr review. When done, run notify-complete.sh ${ISSUE_NUMBER} <result> ${PR_NUMBER} where result is: approved, changes-requested, or failed."

exec "${SCRIPT_DIR}/spawn.sh" --agent reviewer --resume --prompt "$REVIEWER_PROMPT" "${FLAGS[@]+"${FLAGS[@]}"}" "$ISSUE_NUMBER"
