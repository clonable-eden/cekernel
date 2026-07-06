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
#   claude_bg_agents_json [extra-args...]
#     — List sessions as JSON. Extra args pass through to `claude agents`
#       (e.g. --all to include finished sessions — the daemon exits after
#       its sessions complete, and only --all keeps a finished session
#       visible across a daemon restart). Fails when the claude CLI is
#       unavailable or errors (Rule of Repair: callers decide how to
#       surface it).
#
#   claude_bg_state_from_json <json> <token>
#     — Echo the state of the session whose sessionId starts with <token>,
#       resolved against a pre-fetched `agents --json` body. Lets view
#       layers (orchctl ps/count) fetch once and join many tokens
#       (ADR-0016 Phase 4).
#     — Returns 1 (echoing nothing) when no session matches.
#
#   claude_bg_state_for_token <token> [extra-args...]
#     — Echo the logical state (busy|blocked|done|stopped|...) of the session
#       whose sessionId starts with <token>. Live sessions report it in
#       `status` (with `state: "working"` or no state); terminal sessions in
#       `state` — the query reads `(.status // .state)` to serve both, plus
#       the legacy pre-split shape (#581). Tokens are opaque: the full UUID
#       when capture succeeded, or the short ID (first 8 hex chars) as a
#       degraded fallback — prefix matching serves both. Extra args pass
#       through to the agents query (e.g. --all).
#     — Returns 1 (echoing nothing) when no session matches or the query fails.
#
#   claude_bg_token_alive_from_json <json> <token>
#     — exit 0 when the session state is busy or blocked (alive), 1
#       otherwise, resolved against a pre-fetched `agents --json` body.
#       blocked means the session waits on a permission dialog — alive but
#       stalled; supervision surfaces it distinctly (ADR-0016). This is the
#       single home of the busy/blocked liveness vocabulary — view layers
#       (orchctl count) delegate here instead of comparing states inline.
#
#   claude_bg_token_alive <token>
#     — Fetching variant of claude_bg_token_alive_from_json: queries
#       `agents --json` itself, then delegates.
#
#   claude_bg_wait_terminal <token> <interval> <timeout>
#     — Poll `agents --json --all` until the session reaches a state that is
#       terminal for UNATTENDED supervision (ADR-0016 Phase 3, cron/at):
#       done, stopped, or blocked — blocked means a permission dialog that
#       no one will ever approve, so waiting longer cannot help. Echoes the
#       final state, or "timeout" when <timeout> seconds elapse first.
#       A transiently missing session (daemon restart window) keeps polling.
#       Always exits 0 — callers map the echoed state to their own outcome.
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

# claude_bg_agents_json [extra-args...]
claude_bg_agents_json() {
  claude agents --json "$@" 2>/dev/null
}

# claude_bg_state_from_json <json> <token>
claude_bg_state_from_json() {
  local json="$1"
  local token="$2"
  local state
  state=$(echo "$json" | jq -r --arg p "$token" \
    '[.[] | select(.sessionId | startswith($p))][0] | (.status // .state) // empty')
  [[ -n "$state" ]] || return 1
  echo "$state"
}

# claude_bg_state_for_token <token> [extra-args...]
claude_bg_state_for_token() {
  local token="$1"
  shift
  local json
  json=$(claude_bg_agents_json "$@") || return 1
  claude_bg_state_from_json "$json" "$token"
}

# claude_bg_token_alive_from_json <json> <token>
claude_bg_token_alive_from_json() {
  local json="$1"
  local token="$2"
  local state
  state=$(claude_bg_state_from_json "$json" "$token") || return 1
  [[ "$state" == "busy" || "$state" == "blocked" ]]
}

# claude_bg_token_alive <token>
claude_bg_token_alive() {
  local token="$1"
  local json
  json=$(claude_bg_agents_json) || return 1
  claude_bg_token_alive_from_json "$json" "$token"
}

# claude_bg_wait_terminal <token> <interval> <timeout>
claude_bg_wait_terminal() {
  local token="${1:?Usage: claude_bg_wait_terminal <token> <interval> <timeout>}"
  local interval="${2:?Usage: claude_bg_wait_terminal <token> <interval> <timeout>}"
  local timeout="${3:?Usage: claude_bg_wait_terminal <token> <interval> <timeout>}"

  # Wall-clock deadline via SECONDS: safe with interval=0 (no elapsed
  # arithmetic that would never advance).
  local deadline=$((SECONDS + timeout))
  local state
  while :; do
    # --all keeps finished sessions visible across a daemon restart; a
    # failed/empty query (daemon restarting) is transient — keep polling.
    state=$(claude_bg_state_for_token "$token" --all) || state=""
    case "$state" in
      done|stopped|blocked)
        echo "$state"
        return 0
        ;;
    esac
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      echo "timeout"
      return 0
    fi
    sleep "$interval"
  done
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
