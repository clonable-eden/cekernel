#!/usr/bin/env bash
# backends/wezterm.sh — WezTerm backend (ADR-0005 API)
#
# Implements 5 external API functions using WezTerm CLI.
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=wezterm.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue}.{type} contains WezTerm pane ID (numeric).

# ── Dependencies ──
_WEZTERM_BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${_WEZTERM_BACKEND_DIR}/../runner.sh"

# ── External API ──

backend_available() {
  command -v wezterm >/dev/null 2>&1
}

# backend_spawn_worker <issue> <type> <worktree> <prompt> <agent-name>
# Spawns a Worker in a WezTerm 3-pane layout.
# Saves pane ID to handle file internally.
backend_spawn_worker() {
  local issue="$1"
  local type="$2"
  local worktree="$3"
  local prompt="$4"
  local agent_name="$5"

  # Resolve workspace (WezTerm-specific)
  local workspace=""
  workspace=$(_backend_resolve_workspace)

  # Generate runner script (handles cd, env, prompt file, claude)
  local runner
  runner=$(write_runner_script "$issue" "$worktree" "${CEKERNEL_SESSION_ID:-}" "$agent_name" "$prompt")

  # Build JSON payload for Lua-side layout construction
  # Only a file path is sent — no escaping concerns
  local layout_payload
  layout_payload=$(jq -n \
    --arg worktree "$worktree" \
    --arg session_id "${CEKERNEL_SESSION_ID:-}" \
    --arg issue_number "$issue" \
    --arg command "bash '${runner}'" \
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

  # Save handle (pane ID)
  echo "$pane_id" > "${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
}

# backend_get_pid <issue> [type]
# Returns the PID of the foreground process in the WezTerm pane.
# WezTerm's .pid field may return null, so falls back to tty_name-based lookup.
backend_get_pid() {
  local issue="$1"
  local type="${2:-}"

  local handle_file
  if [[ -n "$type" ]]; then
    handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
  else
    handle_file=$(ls "${CEKERNEL_IPC_DIR}"/handle-"${issue}".* 2>/dev/null | head -1)
  fi

  if [[ -z "$handle_file" || ! -f "$handle_file" ]]; then
    echo "Error: no handle file for issue #${issue}" >&2
    return 1
  fi

  local pane_id
  pane_id=$(cat "$handle_file")

  local json
  json=$(wezterm cli list --format json 2>/dev/null) || return 1

  # Try .pid field first
  local pid
  pid=$(echo "$json" | jq -r --argjson target "$pane_id" '.[] | select(.pane_id == $target) | .pid' 2>/dev/null)

  if [[ -n "$pid" && "$pid" != "null" ]]; then
    echo "$pid"
    return 0
  fi

  # Fallback: use tty_name to find PID via ps (#297)
  local tty_name
  tty_name=$(echo "$json" | jq -r --argjson target "$pane_id" '.[] | select(.pane_id == $target) | .tty_name' 2>/dev/null)

  if [[ -z "$tty_name" || "$tty_name" == "null" ]]; then
    return 1
  fi

  # Extract tty short name (e.g., /dev/ttys042 -> ttys042) and find claude process
  ps -t "${tty_name##*/}" -o pid= -o comm= 2>/dev/null \
    | awk '/claude/ {print $1; exit}'
}

# backend_worker_alive <issue> [type]
# exit 0 if alive, exit 1 if dead or no handle
# If type is omitted, checks any handle-{issue}.* file.
backend_worker_alive() {
  local issue="$1"
  local type="${2:-}"

  if [[ -n "$type" ]]; then
    local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
    [[ -f "$handle_file" ]] || return 1
    local pane_id
    pane_id=$(cat "$handle_file")
    _backend_pane_alive "$pane_id"
  else
    local found=0
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      found=1
      local pane_id
      pane_id=$(cat "$handle_file")
      if _backend_pane_alive "$pane_id"; then
        return 0
      fi
    done
    [[ "$found" -eq 1 ]] || return 1
    return 1
  fi
}

# backend_kill_worker <issue> [type]
# Kills all panes in the worker's window. No error if handle missing.
# Also cleans up the payload file created by backend_spawn_worker.
# If type is omitted, kills all handle-{issue}.* handles.
backend_kill_worker() {
  local issue="$1"
  local type="${2:-}"

  # Clean up payload file (created by backend_spawn_worker to avoid send-text 1024-byte limit)
  rm -f "${CEKERNEL_IPC_DIR}/payload-${issue}.b64"

  if [[ -n "$type" ]]; then
    local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
    [[ -f "$handle_file" ]] || return 0
    local pane_id
    pane_id=$(cat "$handle_file")
    _backend_kill_window "$pane_id"
  else
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      local pane_id
      pane_id=$(cat "$handle_file")
      _backend_kill_window "$pane_id"
    done
  fi
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
