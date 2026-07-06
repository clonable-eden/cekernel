#!/usr/bin/env bash
# backends/headless.sh — Headless backend (ADR-0005 Amendment 1, ADR-0016 Phase 1)
#
# Delegates Worker spawn and supervision to `claude --bg` background agent
# sessions. The on-demand daemon owns the process; cekernel keeps only an
# opaque session token as the handle:
#
#   spawn       → claude --bg --agent <name> (returns immediately)
#   liveness    → claude agents --json state (busy|blocked = alive)
#   status      → claude agents --json state (blocked surfaced distinctly)
#   termination → claude stop <token> (also reaps lingering done sessions)
#
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=headless.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue}.{type} contains an opaque
# session token — the full session UUID when capture succeeds, or the short
# ID (first 8 hex chars) as a degraded fallback. All lookups prefix-match
# the token against `agents --json` sessionId, so both forms work.
#
# Session-ID capture (ADR-0016 normative order):
#   1. Primary: extract the short ID from the `backgrounded · <short-id>`
#      spawn stdout line, then prefix-match it against sessionId in
#      `claude agents --json`. Deterministic even with concurrent spawns.
#   2. Fallback (stdout parse fails): kind == "background" + cwd + most
#      recent startedAt. The kind filter is mandatory — the Orchestrator
#      shares the repo-root cwd with interactive sessions. cwd is compared
#      against the realpath'd worktree (agents --json reports realpath).
#
# The captured token is also persisted to
# ${CEKERNEL_IPC_DIR}/{type}-{issue}.claude-session-id for post-mortem
# transcript discovery — like .spawned files, it survives cleanup.

# ── Dependencies ──
_HEADLESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${_HEADLESS_DIR}/../bare-mode.sh"

# ── Internal helpers ──

# _headless_agents_json
# Lists active sessions as JSON. Fails when the claude CLI is unavailable
# or errors (Rule of Repair: callers decide how to surface it).
_headless_agents_json() {
  claude agents --json 2>/dev/null
}

# _headless_state_for_token <token>
# Echoes the state of the session whose sessionId starts with <token>.
# Returns 1 (echoing nothing) when no session matches or the query fails.
_headless_state_for_token() {
  local token="$1"
  local json state
  json=$(_headless_agents_json) || return 1
  state=$(echo "$json" | jq -r --arg p "$token" \
    '[.[] | select(.sessionId | startswith($p))][0].state // empty')
  [[ -n "$state" ]] || return 1
  echo "$state"
}

# _headless_capture_session_id <short-id> <cwd>
# Echoes the full session UUID. With a short ID, prefix-matches it against
# agents --json sessionId (primary path). With an empty short ID, falls
# back to the newest background session at <cwd> (must be realpath'd).
# Retries briefly to absorb the spawn → daemon registration race.
_headless_capture_session_id() {
  local short_id="$1"
  local cwd="$2"
  local attempt json full_id

  for attempt in 1 2 3; do
    json=$(_headless_agents_json) || json="[]"
    if [[ -n "$short_id" ]]; then
      full_id=$(echo "$json" | jq -r --arg p "$short_id" \
        '[.[] | select(.sessionId | startswith($p))][0].sessionId // empty')
    else
      full_id=$(echo "$json" | jq -r --arg cwd "$cwd" \
        '[.[] | select(.kind == "background" and .cwd == $cwd)]
         | sort_by(.startedAt) | last // {} | .sessionId // empty')
    fi
    if [[ -n "$full_id" ]]; then
      echo "$full_id"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# ── External API ──

backend_available() {
  # Headless is always available — no external dependency
  return 0
}

# backend_spawn_worker <issue> <type> <worktree> <prompt> <agent-name>
# Spawns a Worker as a `claude --bg` background agent session and captures
# the daemon-assigned session ID as the handle.
backend_spawn_worker() {
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
  # PATH and cekernel env vars; Workers also source it per Bash call.
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
  if ! session_id=$(_headless_capture_session_id "$short_id" "$cwd_real"); then
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

# backend_get_handle <issue> [type]
# Returns the opaque session token for the Worker session.
backend_get_handle() {
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

# backend_worker_status <issue> [type]
# Echoes the session state from `claude agents --json` (busy|blocked|done|
# stopped|...). blocked means the session is waiting on a permission dialog
# — supervision MUST surface it distinctly (ADR-0016).
# Echoes "missing" and returns 1 when no handle exists, the session is not
# listed, or the query fails.
backend_worker_status() {
  local issue="$1"
  local type="${2:-}"

  local token
  if ! token=$(backend_get_handle "$issue" "$type" 2>/dev/null); then
    echo "missing"
    return 1
  fi

  local state
  if ! state=$(_headless_state_for_token "$token"); then
    echo "missing"
    return 1
  fi
  echo "$state"
}

# backend_worker_alive <issue> [type]
# exit 0 if the session is alive (busy or blocked), exit 1 otherwise.
# If type is omitted, checks any handle-{issue}.* file.
backend_worker_alive() {
  local issue="$1"
  local type="${2:-}"

  if [[ -n "$type" ]]; then
    local state
    state=$(backend_worker_status "$issue" "$type" 2>/dev/null) || return 1
    [[ "$state" == "busy" || "$state" == "blocked" ]]
  else
    local handle_file found=0
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      found=1
      local token state
      token=$(cat "$handle_file")
      state=$(_headless_state_for_token "$token" 2>/dev/null) || continue
      if [[ "$state" == "busy" || "$state" == "blocked" ]]; then
        return 0
      fi
    done
    [[ "$found" -eq 1 ]] || return 1
    return 1
  fi
}

# backend_kill_worker <issue> [type]
# Stops the session via `claude stop`. Sessions linger in `done` state
# until explicitly stopped (ADR-0016), so cleanup paths rely on this to
# reap them. No error if handle missing or session already gone.
# If type is omitted, stops all handle-{issue}.* handles.
backend_kill_worker() {
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
