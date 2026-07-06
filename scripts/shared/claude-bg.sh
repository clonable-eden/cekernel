#!/usr/bin/env bash
# claude-bg.sh — Shared helpers for `claude --bg` background agent sessions
#
# ADR-0016: cekernel delegates process spawn and supervision to `claude --bg`
# and the on-demand daemon. These helpers implement the pieces every --bg
# consumer needs: querying `claude agents --json`, resolving an opaque
# session token to its state, and the normative session-ID capture order.
#
# Consumers: backends/headless.sh (Worker spawn/liveness),
# ctl/spawn-orchestrator.sh (Orchestrator spawn), ctl/orchctl.sh
# (count/ps/gc orchestrator liveness).
#
# Usage: source claude-bg.sh
#
# Functions:
#   claude_bg_agents_json
#     — List sessions as JSON. Fails when the claude CLI is unavailable or
#       errors (Rule of Repair: callers decide how to surface it).
#
#   claude_bg_state_for_token <token>
#     — Echo the state (busy|blocked|done|stopped|...) of the session whose
#       sessionId starts with <token>. Tokens are opaque: the full UUID when
#       capture succeeded, or the short ID (first 8 hex chars) as a degraded
#       fallback — prefix matching serves both.
#     — Returns 1 (echoing nothing) when no session matches or the query fails.
#
#   claude_bg_token_alive <token>
#     — exit 0 when the session state is busy or blocked (alive), 1 otherwise.
#       blocked means the session waits on a permission dialog — alive but
#       stalled; supervision surfaces it distinctly (ADR-0016).
#
#   claude_bg_capture_session_id <short-id> <cwd>
#     — Echo the full session UUID (ADR-0016 normative capture order):
#       1. Primary: prefix-match <short-id> against sessionId in
#          `claude agents --json`. Deterministic even with concurrent spawns.
#       2. Fallback (<short-id> empty): newest kind == "background" session
#          at <cwd>. The kind filter is mandatory — background sessions can
#          share their cwd with interactive sessions (#571). <cwd> must be
#          realpath'd (agents --json reports realpath).
#     — Retries briefly to absorb the spawn → daemon registration race.

# claude_bg_agents_json
claude_bg_agents_json() {
  claude agents --json 2>/dev/null
}

# claude_bg_state_for_token <token>
claude_bg_state_for_token() {
  local token="$1"
  local json state
  json=$(claude_bg_agents_json) || return 1
  state=$(echo "$json" | jq -r --arg p "$token" \
    '[.[] | select(.sessionId | startswith($p))][0].state // empty')
  [[ -n "$state" ]] || return 1
  echo "$state"
}

# claude_bg_token_alive <token>
claude_bg_token_alive() {
  local token="$1"
  local state
  state=$(claude_bg_state_for_token "$token") || return 1
  [[ "$state" == "busy" || "$state" == "blocked" ]]
}

# claude_bg_capture_session_id <short-id> <cwd>
claude_bg_capture_session_id() {
  local short_id="$1"
  local cwd="$2"
  local attempt json full_id

  for attempt in 1 2 3; do
    json=$(claude_bg_agents_json) || json="[]"
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
