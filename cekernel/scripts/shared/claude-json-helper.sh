#!/usr/bin/env bash
# claude-json-helper.sh — Safely read/write trust entries in ~/.claude.json
#
# Usage: source claude-json-helper.sh
#
# Functions:
#   acquire_claude_json_lock  — Acquire mkdir-based lock (up to 10s wait)
#   release_claude_json_lock  — Release lock
#   register_trust <path>     — Add trust entry for worktree path
#   unregister_trust <path>   — Remove trust entry for worktree path
#
# Environment variables (overridable for testing):
#   CLAUDE_JSON — Path to ~/.claude.json (default: ${HOME}/.claude.json)
#   LOCK_DIR    — Lock directory (default: ${CLAUDE_JSON}.lock)

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not found. Install it: https://jqlang.github.io/jq/download/" >&2
  return 1
fi

CLAUDE_JSON="${CLAUDE_JSON:-${HOME}/.claude.json}"
LOCK_DIR="${LOCK_DIR:-${CLAUDE_JSON}.lock}"

acquire_claude_json_lock() {
  local max_wait=10
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ "$waited" -ge "$max_wait" ]]; then
      echo "Error: failed to acquire lock after ${max_wait}s" >&2
      return 1
    fi
    sleep 1
  done
}

release_claude_json_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

register_trust() {
  local worktree_path="$1"

  acquire_claude_json_lock || return 1
  trap 'release_claude_json_lock' RETURN

  # Create empty JSON if file does not exist
  if [[ ! -f "$CLAUDE_JSON" ]]; then
    echo '{}' > "$CLAUDE_JSON"
  fi

  local tmp="${CLAUDE_JSON}.tmp.$$"
  jq --arg path "$worktree_path" '
    .projects[$path] = ((.projects[$path] // {}) + {
      hasTrustDialogAccepted: true,
      hasTrustDialogHooksAccepted: true,
      hasCompletedProjectOnboarding: true,
      hasClaudeMdExternalIncludesApproved: true,
      hasClaudeMdExternalIncludesWarningShown: true
    })
  ' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
}

unregister_trust() {
  local worktree_path="$1"

  # Do nothing if file does not exist
  if [[ ! -f "$CLAUDE_JSON" ]]; then
    return 0
  fi

  acquire_claude_json_lock || return 1
  trap 'release_claude_json_lock' RETURN

  local tmp="${CLAUDE_JSON}.tmp.$$"
  jq --arg path "$worktree_path" '
    del(.projects[$path])
  ' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
}
