#!/usr/bin/env bash
# spawn-reviewer.sh — Spawn a Reviewer process (wrapper for spawn.sh --agent reviewer)
#
# Usage: spawn-reviewer.sh [--priority <priority>] <issue-number> [base-branch]
#   priority: critical|high|normal|low or numeric 0-19 (default: normal)
# Output: FIFO path (stdout last line)
# Options:
#   --priority  Set reviewer priority (nice value)
# Note: Always runs with --resume (reuses Worker's worktree). A Reviewer
#       is only spawned after a Worker has completed ci-passed.
# Exit codes:
#   0 — Reviewer spawned successfully
#   1 — General error
#   2 — Max concurrent processes reached (CEKERNEL_MAX_PROCESSES)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Extract issue number from args (skip flags and their values)
ISSUE=""
SKIP_NEXT=0
for arg in "$@"; do
  if [[ "$SKIP_NEXT" -eq 1 ]]; then
    SKIP_NEXT=0; continue
  fi
  case "$arg" in
    --priority) SKIP_NEXT=1 ;;
    [0-9]*) ISSUE="$arg"; break ;;
  esac
done

REVIEWER_PROMPT="Review the PR for issue #${ISSUE}. Read the repository's CLAUDE.md, the issue body (.cekernel-task.md), and the PR diff. Submit your review via gh pr review. When done, run notify-complete.sh ${ISSUE} <result> <pr-number> where result is: approved, changes-requested, or failed."

exec "${SCRIPT_DIR}/spawn.sh" --agent reviewer --resume --prompt "$REVIEWER_PROMPT" "$@"
