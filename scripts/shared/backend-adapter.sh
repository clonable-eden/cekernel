#!/usr/bin/env bash
# backend-adapter.sh — Abstraction layer for Worker process backends
#
# Usage: source backend-adapter.sh
#
# Dispatches to the appropriate backend based on CEKERNEL_BACKEND env var.
# Supported backends: headless (default), wezterm, tmux
#
# Environment:
#   CEKERNEL_BACKEND — Backend to use (default: headless)
#
# External API (6 functions, provided by backends — ADR-0005 Amendment 1,
# ADR-0016 Phase 5):
#   backend_available       — Check if backend is usable
#   backend_spawn_worker    — Start a Worker process (issue, type, worktree, prompt, agent-name)
#   backend_get_handle      — Get the opaque worker token (issue): the
#                             `claude --bg` session token on all backends
#   backend_worker_alive    — Check if Worker is alive (issue): maps to
#                             `claude agents --json` state (busy|blocked)
#   backend_worker_status   — Echo the session state (busy|blocked|done|...)
#   backend_kill_worker     — Terminate a Worker (issue): claude stop +
#                             visualization cleanup on terminal backends
#
# All backends spawn through the shared --bg session core (bg-session.sh).
# Terminal backends (wezterm/tmux) add an attach-only visualization pane
# (`claude attach <token>`); pane close = detach, never worker death
# (ADR-0001 Amendment 1).
#
# Handle files are managed internally by each backend.
# Callers pass only the issue number — never raw pane IDs or session tokens.

# Resolve the directory where this script lives
_BACKEND_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"

# Select backend (default: headless)
CEKERNEL_ACTIVE_BACKEND="${CEKERNEL_BACKEND:-headless}"

_BACKEND_FILE="${_BACKEND_ADAPTER_DIR}/backends/${CEKERNEL_ACTIVE_BACKEND}.sh"

if [[ ! -f "$_BACKEND_FILE" ]]; then
  echo "Error: unknown backend '${CEKERNEL_ACTIVE_BACKEND}'" >&2
  echo "Supported backends: wezterm, tmux, headless" >&2
  return 1 2>/dev/null || exit 1
fi

source "$_BACKEND_FILE"
