#!/usr/bin/env bash
# clear-resume-marker.sh — Standalone wrapper for task_file_clear_resume_marker
#
# Usage: clear-resume-marker.sh <worktree>
#
# Removes the "## Resume Reason: ..." section from .cekernel-task.md in
# the given worktree. This prevents stale resume markers from causing
# incorrect behavior when a Worker is re-spawned after a previous resume cycle.
#
# LLM agents running in zsh can call this standalone command without
# sourcing bash-specific scripts directly (avoids zsh "bad substitution"
# errors from bash-specific syntax).
#
# Example:
#   clear-resume-marker.sh "$PWD"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/task-file.sh"

WORKTREE="${1:?Usage: clear-resume-marker.sh <worktree>}"

task_file_clear_resume_marker "$WORKTREE"
