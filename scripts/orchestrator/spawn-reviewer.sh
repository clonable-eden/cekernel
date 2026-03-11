#!/usr/bin/env bash
# spawn-reviewer.sh — Spawn a Reviewer process (wrapper for spawn.sh --agent reviewer)
#
# Usage: spawn-reviewer.sh [--resume] [--priority <priority>] <issue-number> [base-branch]
#   priority: critical|high|normal|low or numeric 0-19 (default: normal)
# Output: FIFO path (stdout last line)
# Options:
#   --resume    Resume a suspended Reviewer (reuse existing worktree)
#   --priority  Set reviewer priority (nice value)
# Exit codes:
#   0 — Reviewer spawned successfully
#   1 — General error
#   2 — Max concurrent processes reached (CEKERNEL_MAX_PROCESSES)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/spawn.sh" --agent reviewer "$@"
