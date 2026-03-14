#!/usr/bin/env bash
# transcript-locator.sh — Locate Claude Code conversation transcripts for post-mortem analysis
#
# Implements the Transcript Discovery Algorithm from ADR-0013.
# Centralizes path resolution so that changes to Claude Code's storage
# format can be absorbed in one place.
#
# Usage: source transcript-locator.sh
#
# Functions:
#   transcript_locate_worker <issue-number> [claude-home]
#     — Find Worker/Reviewer transcripts by issue number
#     — Outputs one path per line to stdout
#     — Returns 1 if no transcripts found (error on stderr)
#
#   transcript_locate_orchestrator <session-id> [claude-home] [project-slug]
#     — Find Orchestrator subagent transcripts by session ID
#     — Outputs one path per line to stdout
#     — Returns 1 if no transcripts found (error on stderr)
#
#   transcript_locate_all <issue-number> [session-id] [claude-home] [project-slug]
#     — Combine worker + orchestrator transcript discovery
#     — Outputs one path per line to stdout
#     — Returns partial results when only some transcripts are found
#
# Claude Code transcript locations (as of ADR-0013):
#   Worker/Reviewer: ~/.claude/projects/*-issue-{number}-*/*.jsonl
#   Orchestrator:    ~/.claude/projects/<project>/<session-id>/subagents/*.jsonl

# transcript_locate_worker <issue-number> [claude-home]
# Finds Worker/Reviewer transcripts matching the issue number.
# Workers and Reviewers run in worktrees whose directory names contain
# the issue number, so the glob pattern matches directly.
transcript_locate_worker() {
  local issue_number="${1:?Usage: transcript_locate_worker <issue-number> [claude-home]}"
  local claude_home="${2:-${HOME}/.claude}"

  # Validate issue number is numeric
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "transcript_locate_worker: issue number must be numeric: ${issue_number}" >&2
    return 1
  fi

  local projects_dir="${claude_home}/projects"
  local found=0

  # Glob: *-issue-{number}-* matches worktree project directories
  # e.g., -Users-alice-git-repo-.worktrees-issue-42-feat-add-widget
  local pattern="${projects_dir}/*-issue-${issue_number}-*/*.jsonl"

  # Use nullglob behavior via find to avoid literal glob in output
  while IFS= read -r -d '' file; do
    echo "$file"
    found=$((found + 1))
  done < <(find "${projects_dir}" -path "*-issue-${issue_number}-*/*.jsonl" -not -path "*/subagents/*" -print0 2>/dev/null | sort -z)

  if [[ "$found" -eq 0 ]]; then
    echo "No Worker/Reviewer transcripts found for issue #${issue_number}" >&2
    return 1
  fi
}

# transcript_locate_orchestrator <session-id> [claude-home] [project-slug]
# Finds Orchestrator subagent transcripts for a given session.
# The Orchestrator runs as a subagent of the interactive session.
# Transcripts are at: ~/.claude/projects/<project>/<session-id>/subagents/*.jsonl
transcript_locate_orchestrator() {
  local session_id="${1:?Usage: transcript_locate_orchestrator <session-id> [claude-home] [project-slug]}"
  local claude_home="${2:-${HOME}/.claude}"
  local project_slug="${3:-}"

  local projects_dir="${claude_home}/projects"
  local found=0

  local search_base
  if [[ -n "$project_slug" ]]; then
    search_base="${projects_dir}/${project_slug}"
  else
    search_base="${projects_dir}"
  fi

  # Look for subagent transcripts under the session directory
  while IFS= read -r -d '' file; do
    echo "$file"
    found=$((found + 1))
  done < <(find "$search_base" -path "*/${session_id}/subagents/*.jsonl" -print0 2>/dev/null | sort -z)

  if [[ "$found" -eq 0 ]]; then
    echo "No Orchestrator transcripts found for session ${session_id}" >&2
    return 1
  fi
}

# transcript_locate_all <issue-number> [session-id] [claude-home] [project-slug]
# Combines worker + orchestrator transcript discovery.
# Partial success is allowed: returns whatever is found, warns about missing.
transcript_locate_all() {
  local issue_number="${1:?Usage: transcript_locate_all <issue-number> [session-id] [claude-home] [project-slug]}"
  local session_id="${2:-}"
  local claude_home="${3:-${HOME}/.claude}"
  local project_slug="${4:-}"

  local any_found=0

  # Worker/Reviewer transcripts
  if transcript_locate_worker "$issue_number" "$claude_home" 2>/dev/null; then
    any_found=1
  else
    echo "Warning: No Worker/Reviewer transcripts found for issue #${issue_number}" >&2
  fi

  # Orchestrator transcripts (optional — requires session ID)
  if [[ -n "$session_id" ]]; then
    if transcript_locate_orchestrator "$session_id" "$claude_home" "$project_slug" 2>/dev/null; then
      any_found=1
    else
      echo "Warning: No Orchestrator transcripts found for session ${session_id}" >&2
    fi
  fi

  if [[ "$any_found" -eq 0 ]]; then
    echo "No transcripts found for issue #${issue_number}" >&2
    return 1
  fi
}
