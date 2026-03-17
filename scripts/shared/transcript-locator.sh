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
#   transcript_locate_orchestrator_by_issue <issue-number> [var-dir] [claude-home] [project-slug]
#     — Find Orchestrator transcripts by scanning .spawned files for session reverse lookup
#     — Scans ${var-dir}/ipc/*/{worker,reviewer}-{N}.spawned to find session IDs
#     — Outputs one path per line to stdout
#     — Returns 1 if no .spawned files or no transcripts found
#
#   transcript_locate_all <issue-number> [session-id] [claude-home] [project-slug] [var-dir]
#     — Combine worker + orchestrator transcript discovery
#     — Falls back to .spawned-based session lookup when session-id is empty
#     — Outputs one path per line to stdout
#     — Returns partial results when only some transcripts are found
#
# Claude Code transcript locations (as of ADR-0013):
#   Worker/Reviewer: ~/.claude/projects/*-issue-{number}-*/*.jsonl
#   Orchestrator:    ~/.claude/projects/<project>/<session-id>/subagents/*.jsonl

# transcript_locate_worker <issue-number> [claude-home]
# Finds Worker/Reviewer transcripts matching the issue number.
# Workers and Reviewers run in worktrees named .worktrees/issue/{N}-{slug}/
# (see CLAUDE.md "Worktree Naming" for the full convention).
# Claude Code maps worktree paths to project directories by replacing / with -,
# so the glob *-issue-{N}-* matches any worktree for a given issue number.
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
  # e.g., -Users-alice-git-repo--worktrees-issue-42-feat-add-widget
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

# transcript_locate_orchestrator_by_issue <issue-number> [var-dir] [claude-home] [project-slug]
# Finds Orchestrator transcripts by scanning .spawned files for session reverse lookup.
# spawn.sh creates {agent-type}-{N}.spawned in the IPC directory on successful spawn.
# This function scans ${var-dir}/ipc/*/{worker,reviewer}-{N}.spawned to discover
# which session(s) handled the given issue, then locates orchestrator transcripts
# for those sessions. This avoids the need to source session-id.sh (which would
# generate a new session ID) or depend on CEKERNEL_IPC_DIR.
transcript_locate_orchestrator_by_issue() {
  local issue_number="${1:?Usage: transcript_locate_orchestrator_by_issue <issue-number> [var-dir] [claude-home] [project-slug]}"
  local var_dir="${2:-${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}}"
  local claude_home="${3:-${HOME}/.claude}"
  local project_slug="${4:-}"

  # Validate issue number is numeric
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "transcript_locate_orchestrator_by_issue: issue number must be numeric: ${issue_number}" >&2
    return 1
  fi

  local ipc_base="${var_dir}/ipc"
  if [[ ! -d "$ipc_base" ]]; then
    echo "No IPC directory found: ${ipc_base}" >&2
    return 1
  fi

  # Scan for .spawned files matching the issue number
  # Pattern: ${ipc_base}/*/{worker,reviewer}-{issue_number}.spawned
  local seen_file
  seen_file=$(mktemp /tmp/cekernel-seen-sessions.XXXXXX)
  local found_spawned=0

  while IFS= read -r -d '' spawned_file; do
    found_spawned=$((found_spawned + 1))
    # Extract session ID from path: .../ipc/{session-id}/{type}-{N}.spawned
    local session_dir
    session_dir=$(dirname "$spawned_file")
    local session_id
    session_id=$(basename "$session_dir")
    # Deduplicate sessions (multiple agent types for same issue in same session)
    if ! grep -qxF "$session_id" "$seen_file" 2>/dev/null; then
      echo "$session_id" >> "$seen_file"
    fi
  done < <(find "$ipc_base" -maxdepth 2 \( -name "worker-${issue_number}.spawned" -o -name "reviewer-${issue_number}.spawned" \) -print0 2>/dev/null)

  if [[ "$found_spawned" -eq 0 ]]; then
    rm -f "$seen_file"
    echo "No .spawned files found for issue #${issue_number}" >&2
    return 1
  fi

  # For each discovered session, locate orchestrator transcripts
  local any_found=0
  while IFS= read -r session_id; do
    if transcript_locate_orchestrator "$session_id" "$claude_home" "$project_slug" 2>/dev/null; then
      any_found=1
    fi
  done < "$seen_file"

  rm -f "$seen_file"

  if [[ "$any_found" -eq 0 ]]; then
    echo "No Orchestrator transcripts found for issue #${issue_number} (sessions checked from .spawned files)" >&2
    return 1
  fi
}

# transcript_locate_all <issue-number> [session-id] [claude-home] [project-slug] [var-dir]
# Combines worker + orchestrator transcript discovery.
# When session-id is empty, falls back to .spawned-based session reverse lookup.
# Partial success is allowed: returns whatever is found, warns about missing.
transcript_locate_all() {
  local issue_number="${1:?Usage: transcript_locate_all <issue-number> [session-id] [claude-home] [project-slug] [var-dir]}"
  local session_id="${2:-}"
  local claude_home="${3:-${HOME}/.claude}"
  local project_slug="${4:-}"
  local var_dir="${5:-${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}}"

  local any_found=0

  # Worker/Reviewer transcripts
  if transcript_locate_worker "$issue_number" "$claude_home" 2>/dev/null; then
    any_found=1
  else
    echo "Warning: No Worker/Reviewer transcripts found for issue #${issue_number}" >&2
  fi

  # Orchestrator transcripts (explicit session ID or .spawned fallback)
  if [[ -n "$session_id" ]]; then
    if transcript_locate_orchestrator "$session_id" "$claude_home" "$project_slug" 2>/dev/null; then
      any_found=1
    else
      echo "Warning: No Orchestrator transcripts found for session ${session_id}" >&2
    fi
  else
    # Fallback: scan .spawned files for session reverse lookup
    if transcript_locate_orchestrator_by_issue "$issue_number" "$var_dir" "$claude_home" "$project_slug" 2>/dev/null; then
      any_found=1
    fi
  fi

  if [[ "$any_found" -eq 0 ]]; then
    echo "No transcripts found for issue #${issue_number}" >&2
    return 1
  fi
}
