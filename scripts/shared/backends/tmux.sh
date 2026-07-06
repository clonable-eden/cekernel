#!/usr/bin/env bash
# backends/tmux.sh — tmux backend (ADR-0005 API, ADR-0016 Phase 5)
#
# Spawn and supervision delegate to the shared `claude --bg` session core
# (bg-session.sh) — identical to headless. tmux adds an attach-only
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
# Pane file:   ${CEKERNEL_IPC_DIR}/pane-{issue}.{type} contains the tmux
# pane target (e.g. "session:window.pane") — a visualization detail,
# cleaned up on kill.
#
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=tmux.

# ── Dependencies ──
_TMUX_BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${_TMUX_BACKEND_DIR}/../bg-session.sh"

# ── External API ──

backend_available() {
  command -v tmux >/dev/null 2>&1 || return 1
  # Verify tmux server is reachable (not just installed)
  tmux list-sessions >/dev/null 2>&1
}

# backend_spawn_worker <issue> <type> <worktree> <prompt> <agent-name>
# Spawns the Worker session via the shared --bg path, then opens a tmux
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

  # Resolve session (tmux-specific)
  local session=""
  session=$(_backend_resolve_workspace)

  # Spawn main window
  local main_pane
  main_pane=$(_backend_spawn_window "$worktree" "$session")

  # Create right pane (40%) — worker status monitor
  local right_pane
  right_pane=$(_backend_split_pane right 40 "$main_pane" "$worktree" 2>/dev/null) || true
  if [[ -n "$right_pane" ]]; then
    local watch_cmd="watch -n 5 'cat ${CEKERNEL_IPC_DIR}/worker-${issue}.state 2>/dev/null && echo \"---\" && tail -5 ${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log 2>/dev/null'"
    _backend_run_command "$right_pane" "$watch_cmd"
  fi

  # Create bottom pane (25%) — git log
  _backend_split_pane bottom 25 "$main_pane" "$worktree" 2>/dev/null || true

  # Main pane: attach-only viewer. Claude Code session markers are unset
  # defensively — the tmux server env may carry them when it was started
  # from within a Claude session.
  _backend_run_command "$main_pane" \
    "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ACCESS_TOKEN claude attach '${token}'"

  # Save pane target (visualization bookkeeping, separate from the handle)
  echo "$main_pane" > "${CEKERNEL_IPC_DIR}/pane-${issue}.${type}"
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
# window(s), and cleans up pane files. No error if handle missing.
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
  return 0
}

# ── Private API (internal to tmux backend) ──

_backend_resolve_workspace() {
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

# _backend_spawn_window <cwd> [session-name]
# stdout: pane target (session:window.pane)
_backend_spawn_window() {
  local cwd="$1"
  local session="${2:-}"
  local args=()

  if [[ -n "$session" ]]; then
    args+=(-t "$session")
  fi
  args+=(-c "$cwd" -P -F '#{session_name}:#{window_index}.#{pane_index}')

  tmux new-window "${args[@]}"
}

# _backend_run_command <pane-target> <command>
_backend_run_command() {
  local pane_target="$1"
  local cmd="$2"
  tmux send-keys -t "$pane_target" "$cmd" Enter
}

# _backend_split_pane <direction> <percent> <pane-target> <cwd> [command...]
_backend_split_pane() {
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

# _backend_kill_window <pane-target>
# Kill the entire window that the pane belongs to. Closing the window only
# detaches viewers — the session itself is stopped separately via
# bg_session_stop.
_backend_kill_window() {
  local pane_target="$1"

  # Extract session:window from the pane target
  local window_target
  window_target=$(echo "$pane_target" | sed 's/\.[0-9]*$//')

  tmux kill-window -t "$window_target" 2>/dev/null || true
  echo "Killed window: ${window_target}" >&2
}
