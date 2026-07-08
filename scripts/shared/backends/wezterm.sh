#!/usr/bin/env bash
# backends/wezterm.sh — WezTerm backend (ADR-0005 API, ADR-0016 Phase 5)
#
# Spawn and supervision delegate to the shared `claude --bg` session core
# (bg-session.sh) — identical to headless. WezTerm adds an attach-only
# visualization layer: a 3-pane window whose main pane runs
# `claude attach <session-id>` (ADR-0001 Amendment 1).
#
# Pane close = detach, NOT session termination: liveness maps to the
# ADR-0018 session verdict, never pane existence. Killing the worker
# stops the session (via the claude-bg stop primitive) and closes the
# window.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue}.{type} contains the
# opaque session token (see bg-session.sh).
# Pane file:   ${CEKERNEL_IPC_DIR}/pane-{issue}.{type} contains the WezTerm
# pane ID (numeric) — a visualization detail, cleaned up on kill.
#
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=wezterm.

# ── Dependencies ──
_WEZTERM_BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${_WEZTERM_BACKEND_DIR}/../bg-session.sh"

# ── External API ──

backend_available() {
  command -v wezterm >/dev/null 2>&1
}

# backend_spawn_worker <issue> <type> <worktree> <prompt> <agent-name>
# Spawns the Worker session via the shared --bg path, then opens a WezTerm
# 3-pane layout whose main pane attaches to the session.
backend_spawn_worker() {
  local issue="$1"
  local type="$2"
  local worktree="$3"
  local prompt="$4"
  local agent_name="$5"

  # Spawn the session first (Rule of Repair: no window without a session).
  # Writes handle-{issue}.{type} and {type}-{issue}.claude-session-id.
  bg_session_spawn "$issue" "$type" "$worktree" "$prompt" "$agent_name" || return 1

  local token
  token=$(bg_session_get_handle "$issue" "$type")

  # Resolve workspace (WezTerm-specific)
  local workspace=""
  workspace=$(_backend_resolve_workspace)

  # Pane command: attach-only viewer. Claude Code session markers are
  # unset defensively — the mux server env may carry them when it was
  # started from within a Claude session.
  local attach_cmd="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ACCESS_TOKEN claude attach '${token}'"

  # Build JSON payload for Lua-side layout construction
  local layout_payload
  layout_payload=$(jq -n \
    --arg worktree "$worktree" \
    --arg session_id "${CEKERNEL_SESSION_ID:-}" \
    --arg issue_number "$issue" \
    --arg command "$attach_cmd" \
    '{worktree: $worktree, session_id: $session_id, issue_number: $issue_number, command: $command}'
  )

  # Spawn window (IPC 1)
  local pane_id
  pane_id=$(_backend_spawn_window "$worktree" "$workspace")

  # Send OSC user-var to trigger Lua handler (IPC 2-3)
  # Write base64 payload to file to avoid wezterm cli send-text 1024-byte limit.
  # The OSC command uses $(cat ...) to read the payload at execution time.
  local payload_b64
  payload_b64=$(printf '%s' "$layout_payload" | base64 | tr -d '\n')
  local payload_file="${CEKERNEL_IPC_DIR}/payload-${issue}.b64"
  printf '%s' "$payload_b64" > "$payload_file"
  local osc_cmd="printf '\\033]1337;SetUserVar=%s=%s\\007' cekernel_worker_layout \"\$(cat '${payload_file}')\""
  wezterm cli send-text --pane-id "$pane_id" -- "$osc_cmd"
  sleep 0.1
  wezterm cli send-text --pane-id "$pane_id" --no-paste $'\r'

  # Save pane ID (visualization bookkeeping, separate from the handle)
  echo "$pane_id" > "${CEKERNEL_IPC_DIR}/pane-${issue}.${type}"
}

# backend_get_handle <issue> [type]
# Returns the opaque session token (ADR-0005 Amendment 1).
backend_get_handle() {
  bg_session_get_handle "$@"
}

# backend_worker_status <issue> [type]
backend_worker_status() {
  bg_session_status "$@"
}

# backend_worker_alive <issue> [type]
# Session-state liveness: pane close is a detach, never worker death.
backend_worker_alive() {
  bg_session_alive "$@"
}

# backend_kill_worker <issue> [type]
# Stops the session(s) via the claude-bg stop primitive, closes the visualization
# window(s), and cleans up pane/payload files. No error if handle missing.
backend_kill_worker() {
  local issue="$1"
  local type="${2:-}"

  # Stop the session(s) — the daemon owns the process
  bg_session_stop "$issue" "$type"

  # Close the visualization window(s) and clean up pane bookkeeping
  local pane_file
  if [[ -n "$type" ]]; then
    pane_file="${CEKERNEL_IPC_DIR}/pane-${issue}.${type}"
    if [[ -f "$pane_file" ]]; then
      _backend_kill_window "$(cat "$pane_file")"
      rm -f "$pane_file"
    fi
  else
    for pane_file in "${CEKERNEL_IPC_DIR}"/pane-"${issue}".*; do
      [[ -f "$pane_file" ]] || continue
      _backend_kill_window "$(cat "$pane_file")"
      rm -f "$pane_file"
    done
  fi

  # Clean up payload file (created by backend_spawn_worker to avoid the
  # send-text 1024-byte limit)
  rm -f "${CEKERNEL_IPC_DIR}/payload-${issue}.b64"
  return 0
}

# ── Private API (internal to WezTerm backend) ──

_backend_resolve_workspace() {
  if [[ -z "${WEZTERM_PANE:-}" ]]; then
    echo ""
    return 0
  fi

  local json
  json=$(wezterm cli list --format json 2>/dev/null) || {
    echo ""
    return 0
  }

  local workspace
  workspace=$(echo "$json" | jq -r ".[] | select(.pane_id == ${WEZTERM_PANE}) | .workspace" 2>/dev/null) || {
    echo ""
    return 0
  }

  if [[ -z "$workspace" || "$workspace" == "null" ]]; then
    echo ""
    return 0
  fi

  echo "$workspace"
}

# _backend_spawn_window <cwd> [workspace]
# stdout: pane ID
_backend_spawn_window() {
  local cwd="$1"
  local workspace="${2:-}"
  local args=(--new-window --cwd "$cwd")
  if [[ -n "$workspace" ]]; then
    args+=(--workspace "$workspace")
  fi
  wezterm cli spawn "${args[@]}"
}

# _backend_kill_window <pane-id>
# Kill all panes in the pane's window. Falls back to killing the specified
# pane only. Closing panes only detaches viewers — the session itself is
# stopped separately via bg_session_stop.
_backend_kill_window() {
  local pane_id="$1"
  local window_panes
  window_panes=$(wezterm cli list --format json 2>/dev/null \
    | jq -r --argjson target "$pane_id" '
        (map(select(.pane_id == $target)) | first | .window_id) as $win
        | map(select(.window_id == $win)) | .[].pane_id
      ' 2>/dev/null) || true

  if [[ -n "$window_panes" ]]; then
    while IFS= read -r pane; do
      wezterm cli kill-pane --pane-id "$pane" 2>/dev/null || true
    done <<< "$window_panes"
    echo "Killed window panes for pane: ${pane_id}" >&2
  else
    wezterm cli kill-pane --pane-id "$pane_id" 2>/dev/null && \
      echo "Killed pane: ${pane_id}" >&2 || true
  fi
}
