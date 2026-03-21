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
#     — Find Orchestrator transcripts by session ID
#     — Searches both direct JSONL (claude -p) and subagent paths (legacy)
#     — Outputs one path per line to stdout
#     — Returns 1 if no transcripts found (error on stderr)
#
#   transcript_locate_orchestrator_by_issue <issue-number> [var-dir] [claude-home] [project-slug]
#     — Find Orchestrator transcripts by scanning .spawned files for session reverse lookup
#     — Scans ${var-dir}/ipc/*/{worker,reviewer}-{N}.spawned to find session IDs
#     — Supports both subagent path (legacy) and agentSetting scan (claude -p)
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
#   Orchestrator (claude -p):  ~/.claude/projects/<project>/<session-id>.jsonl
#   Orchestrator (legacy):     ~/.claude/projects/<project>/<session-id>/subagents/*.jsonl

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
# Finds Orchestrator transcripts for a given session.
# Searches two paths (claude -p model first, then legacy subagent model):
#   1. Direct JSONL: ~/.claude/projects/<project>/<session-id>.jsonl
#   2. Subagent JSONL: ~/.claude/projects/<project>/<session-id>/subagents/*.jsonl
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

  # Strategy 1 (claude -p model): Direct session JSONL file
  # claude -p creates <project>/<session-id>.jsonl as the top-level transcript
  while IFS= read -r -d '' file; do
    echo "$file"
    found=$((found + 1))
  done < <(find "$search_base" -maxdepth 2 -name "${session_id}.jsonl" -not -path "*/subagents/*" -print0 2>/dev/null | sort -z)

  # Strategy 2 (legacy subagent model): Subagent JSONL files
  # Old model stored at <project>/<parent-session>/subagents/*.jsonl
  while IFS= read -r -d '' file; do
    echo "$file"
    found=$((found + 1))
  done < <(find "$search_base" -path "*/${session_id}/subagents/*.jsonl" -print0 2>/dev/null | sort -z)

  if [[ "$found" -eq 0 ]]; then
    echo "No Orchestrator transcripts found for session ${session_id}" >&2
    return 1
  fi
}

# _transcript_find_orchestrator_jsonl <project-dir>
# Scans top-level JSONL files in a project directory for orchestrator agentSetting.
# claude -p --agent orchestrator creates JSONL files whose first line contains:
#   {"type":"agent-setting","agentSetting":"orchestrator",...}
# Returns matching file paths to stdout. Returns 1 if none found.
_transcript_find_orchestrator_jsonl() {
  local project_dir="${1:?Usage: _transcript_find_orchestrator_jsonl <project-dir>}"
  local found=0

  while IFS= read -r -d '' jsonl_file; do
    # Check first line for orchestrator agentSetting
    local first_line
    first_line=$(head -1 "$jsonl_file" 2>/dev/null) || continue
    if echo "$first_line" | grep -q '"agentSetting"' 2>/dev/null \
       && echo "$first_line" | grep -q '"orchestrator"' 2>/dev/null; then
      echo "$jsonl_file"
      found=$((found + 1))
    fi
  done < <(find "$project_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null | sort -z)

  [[ "$found" -gt 0 ]]
}

# _transcript_derive_main_project_slug <issue-number> <projects-dir>
# Derives the main project slug from worker project directories.
# Worker projects follow the pattern: <main-slug>--worktrees-issue-{N}-{slug}
# (Claude Code converts both / and . to - so /.worktrees/ becomes --worktrees-)
# Splits at --worktrees- to extract the main project slug.
# Returns the slug to stdout, or returns 1 if not derivable.
_transcript_derive_main_project_slug() {
  local issue_number="${1:?Usage: _transcript_derive_main_project_slug <issue-number> <projects-dir>}"
  local projects_dir="$2"

  # Find worker project directories matching the issue number
  local worker_dir
  worker_dir=$(find "$projects_dir" -maxdepth 1 -type d -name "*-issue-${issue_number}-*" -print 2>/dev/null | head -1)

  if [[ -z "$worker_dir" ]]; then
    return 1
  fi

  local worker_slug
  worker_slug=$(basename "$worker_dir")
  # Split at --worktrees- to get main project slug
  # Claude Code converts both / and . to - so .worktrees/ becomes --worktrees-
  local main_slug="${worker_slug%%--worktrees-*}"

  if [[ "$main_slug" == "$worker_slug" ]]; then
    # Pattern didn't match (no --worktrees- found)
    return 1
  fi

  echo "$main_slug"
}

# transcript_locate_orchestrator_by_issue <issue-number> [var-dir] [claude-home] [project-slug]
# Finds Orchestrator transcripts by scanning .spawned files for session reverse lookup.
# spawn.sh creates {agent-type}-{N}.spawned in the IPC directory on successful spawn.
# This function scans ${var-dir}/ipc/*/{worker,reviewer}-{N}.spawned to discover
# which session(s) handled the given issue, then locates orchestrator transcripts
# for those sessions.
#
# Three search strategies (tried in order, short-circuits on first success):
#   1. Legacy (subagent model): Pass session ID to transcript_locate_orchestrator
#      which searches <project>/<session>/subagents/*.jsonl
#   2. UUID lookup: Read orchestrator.claude-session-id from the session's IPC dir
#      to get the Claude Code UUID, then find <project>/<UUID>.jsonl directly
#   3. agentSetting scan: When orchestrator.spawned exists, scan main project dir
#      for JSONL files with orchestrator agentSetting (broadest, slowest)
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

  local projects_dir="${claude_home}/projects"
  local ipc_base="${var_dir}/ipc"
  if [[ ! -d "$ipc_base" ]]; then
    echo "No IPC directory found: ${ipc_base}" >&2
    return 1
  fi

  # Scan for .spawned files matching the issue number
  # Pattern: ${ipc_base}/*/{worker,reviewer}-{issue_number}.spawned
  local seen_file
  seen_file=$(mktemp /tmp/cekernel-seen-sessions.XXXXXX)
  local uuid_file
  uuid_file=$(mktemp /tmp/cekernel-orch-uuids.XXXXXX)
  local found_spawned=0
  local has_orch_spawned=0

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
    # Check for orchestrator.spawned in the same session directory
    if [[ -f "${session_dir}/orchestrator.spawned" ]]; then
      has_orch_spawned=1
    fi
    # Collect Claude Code UUID from orchestrator.claude-session-id if present
    local orch_uuid_file="${session_dir}/orchestrator.claude-session-id"
    if [[ -f "$orch_uuid_file" ]]; then
      local orch_uuid
      orch_uuid=$(cat "$orch_uuid_file" 2>/dev/null | tr -d '[:space:]')
      if [[ -n "$orch_uuid" ]] && ! grep -qxF "$orch_uuid" "$uuid_file" 2>/dev/null; then
        echo "$orch_uuid" >> "$uuid_file"
      fi
    fi
  done < <(find "$ipc_base" -maxdepth 2 \( -name "worker-${issue_number}.spawned" -o -name "reviewer-${issue_number}.spawned" \) -print0 2>/dev/null)

  if [[ "$found_spawned" -eq 0 ]]; then
    rm -f "$seen_file" "$uuid_file"
    echo "No .spawned files found for issue #${issue_number}" >&2
    return 1
  fi

  # Strategy 1: Pass session IDs to transcript_locate_orchestrator
  # (handles both direct JSONL and legacy subagent paths)
  local any_found=0
  while IFS= read -r session_id; do
    if transcript_locate_orchestrator "$session_id" "$claude_home" "$project_slug" 2>/dev/null; then
      any_found=1
    fi
  done < "$seen_file"

  rm -f "$seen_file"

  # Strategy 2: UUID-based direct lookup via orchestrator.claude-session-id
  # When orchestrator.claude-session-id exists, read the Claude Code UUID
  # and find <project>/<UUID>.jsonl directly (O(1) instead of scanning all files)
  if [[ "$any_found" -eq 0 ]] && [[ -s "$uuid_file" ]]; then
    local main_slug="$project_slug"
    if [[ -z "$main_slug" ]]; then
      main_slug=$(_transcript_derive_main_project_slug "$issue_number" "$projects_dir") || true
    fi

    if [[ -n "$main_slug" ]]; then
      local main_project_dir="${projects_dir}/${main_slug}"
      while IFS= read -r orch_uuid; do
        local uuid_jsonl="${main_project_dir}/${orch_uuid}.jsonl"
        if [[ -f "$uuid_jsonl" ]]; then
          echo "$uuid_jsonl"
          any_found=1
        fi
      done < "$uuid_file"
    fi
  fi

  rm -f "$uuid_file"

  # Strategy 3 (claude -p model): agentSetting-based scan
  # When orchestrator.spawned exists but no transcripts found via session ID or UUID,
  # scan the main project directory for JSONL files with orchestrator agentSetting.
  if [[ "$any_found" -eq 0 && "$has_orch_spawned" -eq 1 ]]; then
    local main_slug="$project_slug"
    if [[ -z "$main_slug" ]]; then
      main_slug=$(_transcript_derive_main_project_slug "$issue_number" "$projects_dir") || true
    fi

    if [[ -n "$main_slug" ]]; then
      local main_project_dir="${projects_dir}/${main_slug}"
      if [[ -d "$main_project_dir" ]] && _transcript_find_orchestrator_jsonl "$main_project_dir"; then
        any_found=1
      fi
    fi
  fi

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
