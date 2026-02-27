#!/usr/bin/env bash
# backends/wezterm.sh — WezTerm backend (ADR-0005 API)
#
# Implements 4 external API functions using WezTerm CLI.
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=wezterm.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue} contains WezTerm pane ID (numeric).

# ── External API ──

backend_available() {
  command -v wezterm >/dev/null 2>&1
}

# backend_spawn_worker <issue> <worktree> <prompt>
# Spawns a Worker in a WezTerm 3-pane layout.
# Saves pane ID to handle file internally.
backend_spawn_worker() {
  local issue="$1"
  local worktree="$2"
  local prompt="$3"

  # Resolve workspace (WezTerm-specific)
  local workspace=""
  workspace=$(_backend_resolve_workspace)

  # Build JSON payload for Lua-side layout construction
  local layout_payload
  layout_payload=$(jq -n \
    --arg worktree "$worktree" \
    --arg session_id "${CEKERNEL_SESSION_ID:-}" \
    --arg prompt "$prompt" \
    --arg issue_number "$issue" \
    '{worktree: $worktree, session_id: $session_id, prompt: $prompt, issue_number: $issue_number}'
  )

  # Spawn window (IPC 1)
  local pane_id
  pane_id=$(_backend_spawn_window "$worktree" "$workspace")

  # Send OSC user-var to trigger Lua handler (IPC 2-3)
  local payload_b64
  payload_b64=$(printf '%s' "$layout_payload" | base64)
  local osc_cmd="printf '\\033]1337;SetUserVar=%s=%s\\007' cekernel_worker_layout '${payload_b64}'"
  wezterm cli send-text --pane-id "$pane_id" -- "$osc_cmd"
  sleep 0.1
  wezterm cli send-text --pane-id "$pane_id" --no-paste $'\r'

  # Save handle (pane ID)
  echo "$pane_id" > "${CEKERNEL_IPC_DIR}/handle-${issue}"
}

# backend_worker_alive <issue>
# exit 0 if alive, exit 1 if dead or no handle
backend_worker_alive() {
  local issue="$1"
  local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}"

  [[ -f "$handle_file" ]] || return 1

  local pane_id
  pane_id=$(cat "$handle_file")
  _backend_pane_alive "$pane_id"
}

# backend_kill_worker <issue>
# Kills all panes in the worker's window. No error if handle missing.
backend_kill_worker() {
  local issue="$1"
  local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}"

  [[ -f "$handle_file" ]] || return 0

  local pane_id
  pane_id=$(cat "$handle_file")
  _backend_kill_window "$pane_id"
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

# _backend_run_command <pane-id> <command>
_backend_run_command() {
  local pane_id="$1"
  local cmd="$2"
  wezterm cli send-text --pane-id "$pane_id" -- "$cmd"
  wezterm cli send-text --pane-id "$pane_id" --no-paste $'\r'
}

# _backend_split_pane <direction> <percent> <pane-id> <cwd> [command...]
_backend_split_pane() {
  local direction="$1"
  local percent="$2"
  local pane_id="$3"
  local cwd="$4"
  shift 4
  local args=(
    "--${direction}" --percent "$percent"
    --pane-id "$pane_id"
    --cwd "$cwd"
  )
  if [[ $# -gt 0 ]]; then
    args+=(-- "$@")
  fi
  wezterm cli split-pane "${args[@]}"
}

# _backend_pane_alive <pane-id>
_backend_pane_alive() {
  local pane_id="$1"
  wezterm cli list --format json 2>/dev/null \
    | jq -e --argjson target "$pane_id" 'any(.[]; .pane_id == $target)' >/dev/null 2>&1
}

# _backend_kill_window <pane-id>
# Kill all panes in the pane's window. Falls back to killing the specified pane only.
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
