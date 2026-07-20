#!/usr/bin/env bash
# bg-session.sh — Shared `claude --bg` session core (ADR-0016 Phase 1/5)
#
# Usage: source bg-session.sh
#
# The single spawn/supervision path for all backends. Worker sessions are
# spawned as `claude --bg` background agents supervised by the on-demand
# daemon; cekernel keeps only an opaque session token as the handle.
#
# Layer position (ADR-0018): this is the lifecycle core ABOVE the CLI
# surface — it consumes claude-bg.sh predicates only and never parses
# `agents --json` output or invokes the claude CLI itself:
#
#   spawn       → claude_bg_spawn + claude_bg_capture_session_id
#   liveness    → claude_bg_token_verdict (alive|blocked|stale-blocked = alive)
#   status      → claude_bg_token_verdict (verdict vocabulary passthrough)
#   termination → claude_bg_stop (also reaps lingering done sessions)
#
# Terminal backends (wezterm/tmux) layer an attach-only visualization pane
# on top of this core (ADR-0001 Amendment 1); headless uses it as-is.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue}.{type} contains an opaque
# session token — the full session UUID when capture succeeds, or the short
# ID (first 8 hex chars) as a degraded fallback. All lookups prefix-match
# the token against the session roster, so both forms work.
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
#     Echoes the ADR-0018 verdict vocabulary with matching exit codes:
#     alive|blocked|done|stopped (exit 0), not-listed (exit 3),
#     query-failed (exit 4 — transient, callers must NOT treat it as a
#     crash, #573), unknown-value (exit 5); plus "missing" (exit 1) when
#     no handle file exists for the issue.
#   bg_session_alive <issue> [type]
#     exit 0 iff a session for the issue is alive, blocked, or
#     stale-blocked (phantom blocked — an occupied session for every
#     predicate consumer, ADR-0018 Amendment 1 Decision 3). Boolean
#     projection — callers that need a degradation policy for
#     query-failed / unknown-value must use bg_session_status instead.
#   bg_session_stop <issue> [type]
#     Stops the session(s) via the claude-bg stop primitive. Never fails.

# ── Dependencies ──
# The claude CLI surface (spawn/query/stop) is owned by shared/claude-bg.sh
# (ADR-0018 Decision 1) — shared with ctl/spawn-orchestrator.sh and
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

  # Session env is guaranteed by the SPAWNER, not the daemon (ADR-0018
  # Decision 3, #589): source .cekernel-env in the spawn subshell so a
  # daemon auto-started by this call inherits PATH and CEKERNEL_* values.
  # A PRE-EXISTING daemon serves its own (possibly stale) env — its
  # inherited environment is declared unspecified — so Workers also
  # source .cekernel-env per Bash call (the normative mechanism).
  # `--bg --bare` with a prompt composes without warnings (verified
  # v2.1.201, 2026-07-07 — unlike the hidden --exec path). stderr is
  # discarded — analysis uses transcripts.
  local short_id
  short_id=$(
    cd "$worktree" && \
    source .cekernel-env && \
    claude_bg_spawn "$worktree" "${CEKERNEL_BARE_FLAGS[@]}" \
      --agent "$agent_name" "$prompt" 2>/dev/null
  ) || {
    echo "Error: claude --bg spawn failed for issue #${issue}" >&2
    return 1
  }

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
# Echoes the ADR-0018 verdict for the session (see header). "missing"
# (exit 1) means no handle file exists — distinct from not-listed, where a
# handle exists but no session matches it. blocked means the session is
# waiting on a permission dialog — supervision MUST surface it distinctly
# (ADR-0016). query-failed (exit 4) is transient (daemon restarting) —
# callers must NOT treat it as a crash (#573).
bg_session_status() {
  local issue="$1"
  local type="${2:-}"

  local token
  if ! token=$(bg_session_get_handle "$issue" "$type" 2>/dev/null); then
    echo "missing"
    return 1
  fi

  claude_bg_token_verdict "$token"
}

# bg_session_alive <issue> [type]
# exit 0 if the session is alive (alive, blocked, or stale-blocked
# verdict — stale-blocked is an occupied session, ADR-0018 Amendment 1),
# exit 1 otherwise. If type is omitted, checks any handle-{issue}.* file.
# Boolean projection: non-verdict reports (query-failed, unknown-value)
# count as not-confirmably-alive here — callers needing a degradation
# policy must branch on bg_session_status.
bg_session_alive() {
  local issue="$1"
  local type="${2:-}"

  if [[ -n "$type" ]]; then
    local verdict
    verdict=$(bg_session_status "$issue" "$type" 2>/dev/null) || return 1
    [[ "$verdict" == "alive" || "$verdict" == "blocked" || "$verdict" == "stale-blocked" ]]
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
# Stops the session via the claude-bg stop primitive. Sessions linger in a
# done state until explicitly stopped (ADR-0016), so cleanup paths rely on
# this to reap them. No error if handle missing or session already gone.
# If type is omitted, stops all handle-{issue}.* handles.
bg_session_stop() {
  local issue="$1"
  local type="${2:-}"

  local handle_file
  if [[ -n "$type" ]]; then
    handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
    [[ -f "$handle_file" ]] || return 0
    claude_bg_stop "$(cat "$handle_file")"
  else
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      claude_bg_stop "$(cat "$handle_file")"
    done
  fi
  return 0
}
