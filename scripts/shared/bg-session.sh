#!/usr/bin/env bash
# bg-session.sh — Shared `claude --bg` session core (ADR-0016 Phase 1/5)
#
# Usage: source bg-session.sh
#
# The single spawn/supervision path for all backends. Worker sessions are
# spawned as `claude --bg` background agents supervised by the on-demand
# daemon; cekernel keeps only an opaque session token as the handle:
#
#   spawn       → claude --bg --agent <name> (returns immediately)
#   liveness    → claude agents --json state (busy|blocked = alive)
#   status      → claude agents --json state (blocked surfaced distinctly)
#   termination → claude stop <token> (also reaps lingering done sessions)
#
# Terminal backends (wezterm/tmux) layer an attach-only visualization pane
# on top of this core (ADR-0001 Amendment 1); headless uses it as-is.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue}.{type} contains an opaque
# session token — the full session UUID when capture succeeds, or the short
# ID (first 8 hex chars) as a degraded fallback. All lookups prefix-match
# the token against `agents --json` sessionId, so both forms work.
#
# Session-ID capture follows the ADR-0016 normative order implemented in
# claude-bg.sh (claude_bg_capture_session_id): short-ID prefix match first,
# then kind == "background" + cwd + newest startedAt as fallback.
#
# The captured token is also persisted to
# ${CEKERNEL_IPC_DIR}/{type}-{issue}.claude-session-id for post-mortem
# transcript discovery — like .spawned files, it survives cleanup.
#
# Functions:
#   bg_session_spawn <issue> <type> <worktree> <prompt> <agent-name>
#     Spawns the session, captures the token, writes handle +
#     claude-session-id files. Silent on success; returns 1 on failure.
#   bg_session_get_handle <issue> [type]
#     Echoes the opaque session token from the handle file.
#   bg_session_status <issue> [type]
#     Echoes the agents --json state (busy|blocked|done|...); "missing"
#     with exit 1 when the handle or session is verifiably absent;
#     "unknown" with exit 1 when the agents query fails (transient).
#   bg_session_alive <issue> [type]
#     exit 0 iff a session for the issue is busy or blocked.
#   bg_session_stop <issue> [type]
#     Stops the session(s) via `claude stop`. Never fails.

# ── Dependencies ──
# Session query / token state / capture primitives live in shared/claude-bg.sh
# (ADR-0016 Phase 2 extraction) — shared with ctl/spawn-orchestrator.sh and
# ctl/orchctl.sh. This file layers the Worker handle-file lifecycle on top.
_BG_SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${_BG_SESSION_DIR}/bare-mode.sh"
source "${_BG_SESSION_DIR}/claude-bg.sh"

# ── Session API ──

# bg_session_spawn <issue> <type> <worktree> <prompt> <agent-name>
# Spawns a Worker as a `claude --bg` background agent session and captures
# the daemon-assigned session ID as the handle.
bg_session_spawn() {
  local issue="$1"
  local type="$2"
  local worktree="$3"
  local prompt="$4"
  local agent_name="$5"

  # --bare is conditional on auth availability (ADR-0016 Amendment 1):
  # bare_mode_prepare drops --bare (OAuth/keychain auth) with a stderr
  # notice when no bare-compatible auth path exists. Interactive spawn
  # paths branch instead of hard-failing — only cron/at keeps preflight.
  bare_mode_prepare "$worktree"

  # Launch the session. `claude --bg` returns immediately after printing
  # `backgrounded · <short-id>`; the on-demand daemon supervises it.
  # Source .cekernel-env so the daemon (when auto-started here) inherits
  # PATH and cekernel env vars. Sessions inherit the DAEMON's env, not
  # this subshell's (verified 2026-07-07, v2.1.202) — a pre-existing
  # daemon serves its own (possibly stale) env (#589); Workers fall back
  # to sourcing .cekernel-env per Bash call when commands are missing.
  # Unset Claude Code session markers to avoid nested-session detection.
  # `--bg --bare` with a prompt composes without warnings (verified
  # v2.1.201, 2026-07-07 — unlike the hidden --exec path).
  local spawn_out
  spawn_out=$(
    cd "$worktree" && \
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN && \
    source .cekernel-env && \
    claude --bg "${CEKERNEL_BARE_FLAGS[@]}" --agent "$agent_name" "$prompt" 2>/dev/null
  ) || {
    echo "Error: claude --bg spawn failed for issue #${issue}" >&2
    return 1
  }

  # Primary capture: short ID from the human-oriented spawn line. Parsed
  # solely to extract the token — structured data comes from agents --json.
  local short_id
  short_id=$(printf '%s\n' "$spawn_out" | awk '/backgrounded/ {print $NF; exit}')
  [[ "$short_id" =~ ^[0-9a-f]{8}$ ]] || short_id=""

  # agents --json reports realpath'd cwd (e.g. /tmp → /private/tmp)
  local cwd_real
  cwd_real=$(cd "$worktree" && pwd -P)

  local session_id
  if ! session_id=$(claude_bg_capture_session_id "$short_id" "$cwd_real"); then
    if [[ -n "$short_id" ]]; then
      # Degraded: the short ID is a usable prefix token (liveness/stop work),
      # but transcript direct lookup needs the full UUID — warn, don't fail.
      echo "Warning: could not resolve full session UUID for issue #${issue};" \
        "using short ID ${short_id}" >&2
      session_id="$short_id"
    else
      echo "Error: session-ID capture failed for issue #${issue}" \
        "(no short ID in spawn output, no matching background session)" >&2
      return 1
    fi
  fi

  # Save handle (opaque session token)
  echo "$session_id" > "${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
  # Persist for post-mortem transcript discovery (survives cleanup)
  echo "$session_id" > "${CEKERNEL_IPC_DIR}/${type}-${issue}.claude-session-id"
}

# bg_session_get_handle <issue> [type]
# Returns the opaque session token for the Worker session.
bg_session_get_handle() {
  local issue="$1"
  local type="${2:-}"

  local handle_file
  if [[ -n "$type" ]]; then
    handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
  else
    # Find any handle file for this issue
    handle_file=$(ls "${CEKERNEL_IPC_DIR}"/handle-"${issue}".* 2>/dev/null | head -1)
  fi

  if [[ -z "$handle_file" || ! -f "$handle_file" ]]; then
    echo "Error: no handle file for issue #${issue}" >&2
    return 1
  fi

  cat "$handle_file"
}

# bg_session_status <issue> [type]
# Echoes the session state from `claude agents --json` (busy|blocked|done|
# stopped|...). blocked means the session is waiting on a permission dialog
# — supervision MUST surface it distinctly (ADR-0016).
# Echoes "missing" and returns 1 when no handle exists or the session is
# verifiably not listed. Echoes "unknown" and returns 1 when the agents
# query itself fails (daemon restarting) — a transient condition callers
# must NOT treat as a crash (#573).
bg_session_status() {
  local issue="$1"
  local type="${2:-}"

  local token
  if ! token=$(bg_session_get_handle "$issue" "$type" 2>/dev/null); then
    echo "missing"
    return 1
  fi

  local json
  if ! json=$(claude_bg_agents_json); then
    echo "unknown"
    return 1
  fi
  local state
  if ! state=$(claude_bg_state_from_json "$json" "$token"); then
    echo "missing"
    return 1
  fi
  echo "$state"
}

# bg_session_alive <issue> [type]
# exit 0 if the session is alive (busy or blocked), exit 1 otherwise.
# If type is omitted, checks any handle-{issue}.* file.
bg_session_alive() {
  local issue="$1"
  local type="${2:-}"

  if [[ -n "$type" ]]; then
    local state
    state=$(bg_session_status "$issue" "$type" 2>/dev/null) || return 1
    [[ "$state" == "busy" || "$state" == "blocked" ]]
  else
    local handle_file
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      local token
      token=$(cat "$handle_file")
      if claude_bg_token_alive "$token" 2>/dev/null; then
        return 0
      fi
    done
    return 1
  fi
}

# bg_session_stop <issue> [type]
# Stops the session via `claude stop`. Sessions linger in `done` state
# until explicitly stopped (ADR-0016), so cleanup paths rely on this to
# reap them. No error if handle missing or session already gone.
# If type is omitted, stops all handle-{issue}.* handles.
bg_session_stop() {
  local issue="$1"
  local type="${2:-}"

  if [[ -n "$type" ]]; then
    local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
    [[ -f "$handle_file" ]] || return 0
    local token
    token=$(cat "$handle_file")
    [[ -n "$token" ]] && claude stop "$token" >/dev/null 2>&1 || true
  else
    local handle_file
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      local token
      token=$(cat "$handle_file")
      [[ -n "$token" ]] && claude stop "$token" >/dev/null 2>&1 || true
    done
  fi
  return 0
}
