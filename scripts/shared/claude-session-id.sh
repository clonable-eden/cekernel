#!/usr/bin/env bash
# claude-session-id.sh — Persist and read the Orchestrator's Claude Code session ID
#
# Claude Code stores conversation transcripts at:
#   ~/.claude/projects/<project-slug>/<session-uuid>.jsonl
#
# The <session-uuid> is Claude Code's internal session identifier (a UUID),
# distinct from cekernel's CEKERNEL_SESSION_ID. This helper bridges the two
# by persisting the Claude Code session ID into the cekernel IPC directory.
#
# The ID is captured deterministically at spawn time by
# spawn-orchestrator.sh from the `claude --bg` output (ADR-0016 Phase 2).
# The former newest-transcript discovery heuristic is gone — it
# mis-attributed concurrent sessions (#571).
#
# Usage: source claude-session-id.sh
#
# Functions:
#   claude_session_id_persist <session-id>
#     — Save session ID to ${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id
#     — Requires CEKERNEL_IPC_DIR to be set
#     — Returns 1 if CEKERNEL_IPC_DIR is not set
#
#   claude_session_id_read
#     — Read the persisted session ID from ${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id
#     — Output: session ID string to stdout
#     — Returns 1 if file not found or CEKERNEL_IPC_DIR not set

# claude_session_id_persist <session-id>
# Saves the Claude Code session ID to the IPC directory.
claude_session_id_persist() {
  if [[ -z "${CEKERNEL_IPC_DIR:-}" ]]; then
    echo "Error: CEKERNEL_IPC_DIR not set. Source session-id.sh first." >&2
    return 1
  fi

  local session_id="${1:?Usage: claude_session_id_persist <session-id>}"

  local target="${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id"
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

  local target="${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id"

  if [[ ! -f "$target" ]]; then
    echo "claude_session_id_read: file not found: ${target}" >&2
    return 1
  fi

  cat "$target"
}
