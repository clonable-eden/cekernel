#!/usr/bin/env bash
# backends/headless.sh — Headless backend (ADR-0005 Amendment 1, ADR-0016 Phase 1)
#
# Thin delegation to the shared `claude --bg` session core (bg-session.sh):
# spawn, liveness, status, and termination all map 1:1 onto the session
# API. Headless adds no visualization layer — the session core IS the
# backend. See bg-session.sh for the full contract (handle files,
# session-ID capture order, state semantics).
#
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=headless.

# ── Dependencies ──
_HEADLESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${_HEADLESS_DIR}/../bg-session.sh"

# ── External API ──

backend_available() {
  # Headless is always available — no external dependency
  return 0
}

# backend_spawn_worker <issue> <type> <worktree> <prompt> <agent-name>
backend_spawn_worker() {
  bg_session_spawn "$@"
}

# backend_get_handle <issue> [type]
backend_get_handle() {
  bg_session_get_handle "$@"
}

# backend_worker_status <issue> [type]
backend_worker_status() {
  bg_session_status "$@"
}

# backend_worker_alive <issue> [type]
backend_worker_alive() {
  bg_session_alive "$@"
}

# backend_kill_worker <issue> [type]
backend_kill_worker() {
  bg_session_stop "$@"
}
