#!/usr/bin/env bash
# claude-session-id.sh — Discover, persist, and read Claude Code session IDs
#
# Claude Code stores conversation transcripts at:
#   ~/.claude/projects/<project-slug>/<session-uuid>.jsonl
#
# The <session-uuid> is Claude Code's internal session identifier (a UUID),
# distinct from cekernel's CEKERNEL_SESSION_ID. This helper bridges the two
# by persisting the Claude Code session ID into the cekernel IPC directory.
#
# Usage: source claude-session-id.sh
#
# Functions:
#   claude_session_id_project_slug <project-root>
#     — Convert a project root path to Claude Code's project slug format
#     — Output: hyphen-delimited path (e.g., /Users/alice/git/repo → -Users-alice-git-repo)
#
#   claude_session_id_discover <project-root> [claude-home]
#     — Discover the current Claude Code session ID by finding the most
#       recently modified .jsonl in the project's Claude directory
#     — Output: UUID string to stdout
#     — Returns 1 if project directory or .jsonl files not found
#
#   claude_session_id_persist <session-id>
#     — Save session ID to ${CEKERNEL_IPC_DIR}/claude-session-id
#     — Requires CEKERNEL_IPC_DIR to be set
#     — Returns 1 if CEKERNEL_IPC_DIR is not set
#
#   claude_session_id_read
#     — Read the persisted session ID from ${CEKERNEL_IPC_DIR}/claude-session-id
#     — Output: session ID string to stdout
#     — Returns 1 if file not found or CEKERNEL_IPC_DIR not set

# claude_session_id_project_slug <project-root>
# Converts an absolute path to Claude Code's project slug format.
# Claude Code replaces '/' with '-' in the project path.
claude_session_id_project_slug() {
  local project_root="${1:?Usage: claude_session_id_project_slug <project-root>}"
  echo "$project_root" | tr '/' '-'
}

# claude_session_id_discover <project-root> [claude-home]
# Discovers the current Claude Code session ID by finding the most recently
# modified top-level .jsonl file in the project's Claude directory.
claude_session_id_discover() {
  local project_root="${1:?Usage: claude_session_id_discover <project-root> [claude-home]}"
  local claude_home="${2:-${HOME}/.claude}"

  local slug
  slug=$(claude_session_id_project_slug "$project_root")

  local project_dir="${claude_home}/projects/${slug}"

  if [[ ! -d "$project_dir" ]]; then
    echo "claude_session_id_discover: project directory not found: ${project_dir}" >&2
    return 1
  fi

  # Find the most recently modified .jsonl at the top level (not in subagents/)
  local newest
  newest=$(find "$project_dir" -maxdepth 1 -name '*.jsonl' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | head -1)

  if [[ -z "$newest" ]]; then
    echo "claude_session_id_discover: no .jsonl files found in ${project_dir}" >&2
    return 1
  fi

  # Extract session UUID from filename (basename without .jsonl extension)
  local filename
  filename=$(basename "$newest" .jsonl)
  echo "$filename"
}

# claude_session_id_persist <session-id>
# Saves the Claude Code session ID to the IPC directory.
claude_session_id_persist() {
  if [[ -z "${CEKERNEL_IPC_DIR:-}" ]]; then
    echo "Error: CEKERNEL_IPC_DIR not set. Source session-id.sh first." >&2
    return 1
  fi

  local session_id="${1:?Usage: claude_session_id_persist <session-id>}"

  local target="${CEKERNEL_IPC_DIR}/claude-session-id"
  local tmp="${target}.tmp"

  echo "$session_id" > "$tmp"
  mv -f "$tmp" "$target"
}

# claude_session_id_read
# Reads the persisted Claude Code session ID from the IPC directory.
claude_session_id_read() {
  if [[ -z "${CEKERNEL_IPC_DIR:-}" ]]; then
    echo "Error: CEKERNEL_IPC_DIR not set. Source session-id.sh first." >&2
    return 1
  fi

  local target="${CEKERNEL_IPC_DIR}/claude-session-id"

  if [[ ! -f "$target" ]]; then
    echo "claude_session_id_read: file not found: ${target}" >&2
    return 1
  fi

  cat "$target"
}
