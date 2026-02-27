#!/usr/bin/env bash
# terminal-adapter.sh — Abstraction layer for terminal multiplexer
#
# Usage: source terminal-adapter.sh
#
# Dispatches to the appropriate backend based on CEKERNEL_TERMINAL env var.
# Supported backends: wezterm (default), tmux
#
# Environment:
#   CEKERNEL_TERMINAL — Backend to use (default: wezterm)
#
# Functions (provided by backends):
#   terminal_available          — Check if terminal multiplexer is available
#   terminal_resolve_workspace  — Return workspace/session name
#   terminal_spawn_window       — Create new window and return pane ID
#   terminal_run_command        — Execute command in specified pane
#   terminal_split_pane         — Split pane (optionally run command)
#   terminal_kill_pane          — Kill a pane
#   terminal_kill_window        — Kill all panes in the pane's window
#   terminal_pane_alive         — Check if pane is alive
#   terminal_spawn_worker_layout — Spawn Worker layout (3-pane)

# Resolve the directory where this script lives
_TERMINAL_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Select backend (default: wezterm)
CEKERNEL_TERMINAL_BACKEND="${CEKERNEL_TERMINAL:-wezterm}"

_BACKEND_FILE="${_TERMINAL_ADAPTER_DIR}/backends/${CEKERNEL_TERMINAL_BACKEND}.sh"

if [[ ! -f "$_BACKEND_FILE" ]]; then
  echo "Error: unknown terminal backend '${CEKERNEL_TERMINAL_BACKEND}'" >&2
  echo "Supported backends: wezterm, tmux" >&2
  return 1 2>/dev/null || exit 1
fi

source "$_BACKEND_FILE"
