#!/usr/bin/env bash
# terminal-adapter.sh — Abstraction layer for terminal multiplexer
#
# Usage: source terminal-adapter.sh
#
# Wraps WezTerm-specific operations behind functions, eliminating direct
# dependencies from other scripts. To support tmux etc. in the future,
# only this file needs to be replaced (Rule of Separation).
#
# Functions:
#   terminal_available          — Check if terminal multiplexer is available
#   terminal_resolve_workspace  — Return workspace name of current pane
#   terminal_spawn_window       — Create new window and return pane ID
#   terminal_run_command        — Execute command in specified pane
#   terminal_split_pane         — Split pane (optionally run command)
#   terminal_kill_pane          — Kill a pane
#   terminal_kill_window        — Kill all panes in the pane's window
#   terminal_pane_alive         — Check if pane is alive

terminal_available() {
  command -v wezterm >/dev/null 2>&1
}

terminal_resolve_workspace() {
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

# terminal_spawn_window <cwd> [workspace]
# stdout: pane ID
terminal_spawn_window() {
  local cwd="$1"
  local workspace="${2:-}"
  local args=(--new-window --cwd "$cwd")
  if [[ -n "$workspace" ]]; then
    args+=(--workspace "$workspace")
  fi
  wezterm cli spawn "${args[@]}"
}

# terminal_run_command <pane-id> <command>
terminal_run_command() {
  local pane_id="$1"
  local cmd="$2"
  wezterm cli send-text --pane-id "$pane_id" -- "$cmd"
  wezterm cli send-text --pane-id "$pane_id" --no-paste $'\r'
}

# terminal_split_pane <direction> <percent> <pane-id> <cwd> [command...]
# direction: bottom | right
terminal_split_pane() {
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

# terminal_kill_pane <pane-id>
terminal_kill_pane() {
  local pane_id="$1"
  wezterm cli kill-pane --pane-id "$pane_id" 2>/dev/null || true
}

# terminal_kill_window <pane-id>
# Kill all panes in the pane's window. Falls back to killing the specified pane only.
terminal_kill_window() {
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

# terminal_pane_alive <pane-id>
# exit 0 if alive, exit 1 if dead
terminal_pane_alive() {
  local pane_id="$1"
  wezterm cli list --format json 2>/dev/null | grep -q "\"pane_id\":${pane_id}[,}]"
}
