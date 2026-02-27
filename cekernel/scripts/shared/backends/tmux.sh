#!/usr/bin/env bash
# backends/tmux.sh — tmux terminal backend
#
# Implements terminal_* functions using tmux.
# Sourced by terminal-adapter.sh when CEKERNEL_TERMINAL=tmux.
#
# Pane IDs use tmux target format: "session:window.pane" (e.g., "cekernel:1.0")

terminal_available() {
  command -v tmux >/dev/null 2>&1
}

# terminal_resolve_workspace
# Returns the current tmux session name (analogous to WezTerm workspace).
terminal_resolve_workspace() {
  if [[ -z "${TMUX:-}" ]]; then
    echo ""
    return 0
  fi

  local session
  session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || {
    echo ""
    return 0
  }

  if [[ -z "$session" || "$session" == "null" ]]; then
    echo ""
    return 0
  fi

  echo "$session"
}

# terminal_spawn_window <cwd> [session-name]
# stdout: pane target (session:window.pane)
terminal_spawn_window() {
  local cwd="$1"
  local session="${2:-}"
  local args=()

  if [[ -n "$session" ]]; then
    args+=(-t "$session")
  fi
  args+=(-c "$cwd" -P -F '#{session_name}:#{window_index}.#{pane_index}')

  tmux new-window "${args[@]}"
}

# terminal_run_command <pane-target> <command>
terminal_run_command() {
  local pane_target="$1"
  local cmd="$2"
  tmux send-keys -t "$pane_target" "$cmd" Enter
}

# terminal_split_pane <direction> <percent> <pane-target> <cwd> [command...]
# direction: bottom | right
terminal_split_pane() {
  local direction="$1"
  local percent="$2"
  local pane_target="$3"
  local cwd="$4"
  shift 4

  local split_flag
  if [[ "$direction" == "bottom" ]]; then
    split_flag="-v"
  else
    split_flag="-h"
  fi

  local args=(
    "$split_flag" -t "$pane_target"
    -p "$percent"
    -c "$cwd"
    -P -F '#{session_name}:#{window_index}.#{pane_index}'
  )

  if [[ $# -gt 0 ]]; then
    args+=("$@")
  fi

  tmux split-window "${args[@]}"
}

# terminal_kill_pane <pane-target>
terminal_kill_pane() {
  local pane_target="$1"
  tmux kill-pane -t "$pane_target" 2>/dev/null || true
}

# terminal_kill_window <pane-target>
# Kill the entire window that the pane belongs to.
terminal_kill_window() {
  local pane_target="$1"

  # Extract session:window from the pane target
  local window_target
  window_target=$(echo "$pane_target" | sed 's/\.[0-9]*$//')

  tmux kill-window -t "$window_target" 2>/dev/null || true
  echo "Killed window: ${window_target}" >&2
}

# terminal_pane_alive <pane-target>
# exit 0 if alive, exit 1 if dead
terminal_pane_alive() {
  local pane_target="$1"
  tmux list-panes -t "$pane_target" >/dev/null 2>&1
}

# terminal_spawn_worker_layout <cwd> <session-name> <json-payload>
# Spawn a new window with 3-pane layout for Worker.
# Unlike WezTerm (which uses Lua-side OSC handler), tmux creates the layout
# directly using split-window commands.
# stdout: main pane target
terminal_spawn_worker_layout() {
  local cwd="$1"
  local session="${2:-}"
  local payload="$3"

  # 1) Spawn main window
  local main_pane
  main_pane=$(terminal_spawn_window "$cwd" "$session")

  # Extract the prompt from the JSON payload for reference
  # The actual Claude Code command will be sent by the caller via terminal_run_command

  # 2) Create right pane (40%) — terminal
  local window_target
  window_target=$(echo "$main_pane" | sed 's/\.[0-9]*$//')
  terminal_split_pane right 40 "$main_pane" "$cwd" 2>/dev/null || true

  # 3) Create bottom pane (25%) — git log
  terminal_split_pane bottom 25 "$main_pane" "$cwd" 2>/dev/null || true

  echo "$main_pane"
}
