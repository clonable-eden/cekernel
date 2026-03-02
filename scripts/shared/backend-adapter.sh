#!/usr/bin/env bash
# backend-adapter.sh — Abstraction layer for Worker process backends
#
# Usage: source backend-adapter.sh
#
# Dispatches to the appropriate backend based on CEKERNEL_BACKEND env var.
# Supported backends: wezterm (default), tmux, headless
#
# Environment:
#   CEKERNEL_BACKEND — Backend to use (default: wezterm)
#
# External API (4 functions, provided by backends):
#   backend_available       — Check if backend is usable
#   backend_spawn_worker    — Start a Worker process (issue, worktree, prompt)
#   backend_worker_alive    — Check if Worker is alive (issue)
#   backend_kill_worker     — Terminate a Worker (issue)
#
# Handle files are managed internally by each backend.
# Callers pass only the issue number — never raw pane IDs or PIDs.

# Resolve the directory where this script lives
_BACKEND_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Select backend (default: wezterm)
CEKERNEL_ACTIVE_BACKEND="${CEKERNEL_BACKEND:-wezterm}"

_BACKEND_FILE="${_BACKEND_ADAPTER_DIR}/backends/${CEKERNEL_ACTIVE_BACKEND}.sh"

if [[ ! -f "$_BACKEND_FILE" ]]; then
  echo "Error: unknown backend '${CEKERNEL_ACTIVE_BACKEND}'" >&2
  echo "Supported backends: wezterm, tmux, headless" >&2
  return 1 2>/dev/null || exit 1
fi

source "$_BACKEND_FILE"
