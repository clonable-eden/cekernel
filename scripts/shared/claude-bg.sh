#!/usr/bin/env bash
# claude-bg.sh — Sole owner of the claude CLI surface (ADR-0018 Decision 1)
#
# ADR-0016: cekernel delegates process spawn and supervision to `claude --bg`
# and the on-demand daemon. ADR-0018: ALL invocation and parsing of the
# claude CLI surface — `claude --bg` spawn output, `claude agents --json`,
# `claude stop` — lives in this module. Raw platform JSON never crosses the
# module boundary: consumers hold `claude_bg_agents_json` output only as an
# OPAQUE snapshot to pass back into the `*_from_json` predicates (single
# fetch, many joins — ADR-0016 Phase 4); parsing it anywhere else is a
# review-blocking violation (CLAUDE.md § Review).
#
# Layer hierarchy (ADR-0018):
#   claude-bg.sh   — CLI surface: the ONLY parser of platform output
#   bg-session.sh  — lifecycle core, predicates only
#   backends / watch / orchctl / wrapper / issue-lock — verdict consumers
#
# ── Observed (status, state) matrix — v2.1.205, 2026-07-09 (ADR-0018) ──
#
#   | `status`  | `state`   | Verdict            |
#   |-----------|-----------|--------------------|
#   | busy      | working   | alive              |
#   | busy      | (absent)  | alive              |
#   | (absent)  | busy      | alive   (pre-split legacy shape)      |
#   | idle      | working   | alive   (v2.1.205: between turns, #638)  |
#   | blocked   | working   | blocked (v2.1.201 shape)              |
#   | idle      | blocked   | blocked (v2.1.202 shape)              |
#   | (absent)  | blocked   | blocked (pre-split legacy shape)      |
#   | idle      | done      | done               |
#   | (absent)  | done      | done    (--all, daemon-restart rows)  |
#   | idle      | stopped   | stopped            |
#   | (absent)  | stopped   | stopped (--all, daemon-restart rows)  |
#   | — session absent —    | not-listed         |
#   | anything else         | unknown-value      |
#
# Liveness lives in `status`, terminality in `state` (#591: reading
# `.status // .state` returned "idle" for done sessions and broke terminal
# detection; #581: reading `.state` alone returned "working" for live
# sessions and killed healthy Workers). This table is the contract — it is
# mirrored in docs/claude-code-constraints.md § Background Agent Sessions
# and tests/helpers/mock-claude.bash (STALENESS COUPLING: update all three
# in the same PR).
#
# ── Report contract (ADR-0018) ──
# Verdict functions echo a token and exit with a matching code. The three
# non-verdict reports are NEVER coerced into alive/dead — degradation
# policy belongs to each consumer (Rule of Separation):
#
#   exit 0 — verdict: alive | blocked | done | stopped
#   exit 3 — not-listed    (no session matches the token; also the shape
#                           of a NOT-RUNNING daemon: `agents --json`
#                           returns [] exit 0 without starting one —
#                           verified v2.1.202, isolated-HOME probe, #593)
#   exit 4 — query-failed  (CLI error / daemon unreachable / malformed body)
#   exit 5 — unknown-value ((status, state) pair not in the matrix; a
#                           stderr warning makes the drift visible —
#                           Rule of Repair)
#
# Usage: source claude-bg.sh
#
# Functions:
#   claude_bg_agents_json [extra-args...]
#     — List sessions as JSON. Extra args pass through to `claude agents`
#       (e.g. --all to include finished sessions — the daemon exits after
#       its sessions complete, and only --all keeps a finished session
#       visible across a daemon restart). Fails when the claude CLI is
#       unavailable or errors. The returned body is an OPAQUE snapshot:
#       consumers may only pass it to the *_from_json predicates below.
#
#   claude_bg_token_verdict_from_json <json> <token>
#     — Resolve <token> (sessionId prefix) against a pre-fetched snapshot
#       and echo the verdict per the report contract above.
#
#   claude_bg_token_verdict <token> [extra-args...]
#     — Fetching variant: queries `agents --json` itself (extra args pass
#       through, e.g. --all), then delegates. Adds the query-failed report
#       when the fetch fails.
#
#   claude_bg_token_alive_from_json <json> <token>
#   claude_bg_token_alive <token>
#     — Boolean projection of the verdict: exit 0 when alive or blocked
#       (blocked = waiting on a permission dialog — alive but stalled,
#       surfaced distinctly by supervision); exit 1 when VERIFIABLY not
#       alive (done, stopped, not-listed). Non-verdict reports propagate
#       unchanged (exit 4 / 5) — callers with a degradation policy must
#       branch on them instead of `if`-coercing.
#
#   claude_bg_spawn <cwd> [claude-args...]
#     — Invoke `claude --bg <claude-args...>` in <cwd> with the nested-
#       session markers unset, and echo the short ID (first 8 hex chars)
#       parsed from the human-oriented `backgrounded · <short-id>` line —
#       or an empty string when the line is unparseable (degraded capture:
#       follow up with claude_bg_capture_session_id). Exit 1 when the
#       spawn itself fails. stdout of claude is consumed here; stderr
#       passes through for the caller to route.
#       Session env is guaranteed by the SPAWNER, not the daemon
#       (ADR-0018 Decision 3, #589): export CEKERNEL_* / PATH before
#       calling — the daemon's inherited environment is unspecified.
#
#   claude_bg_stop <token>
#     — Stop the session via `claude stop`. The token (full UUID or short
#       ID) is truncated to 8 chars — `claude stop` only accepts the
#       short job ID (#621). Never fails (reap semantics: returns 0 even
#       when `claude stop` errors); stop failure emits a stderr warning
#       (Rule of Repair). Empty token is a no-op.
#
#   claude_bg_wait_terminal <token> <interval> <timeout>
#     — Poll `agents --json --all` until the verdict is terminal for
#       UNATTENDED supervision (ADR-0016 Phase 3, cron/at): done, stopped,
#       or blocked — blocked means a permission dialog that no one will
#       ever approve, so waiting longer cannot help. Echoes the final
#       verdict, or "timeout" when <timeout> seconds elapse first.
#       not-listed and query-failed are transient here (daemon restart
#       window) and keep polling; so does unknown-value (drift is not
#       evidence of termination — its stderr warning still surfaces).
#       Always exits 0 — callers map the echoed verdict to their outcome.
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

# claude_bg_token_verdict_from_json <json> <token>
claude_bg_token_verdict_from_json() {
  local json="$1"
  local token="$2"

  # Resolve the record; a jq failure means the snapshot body itself is
  # unusable (malformed platform output) — that is a query failure, not
  # an absence observation.
  local rec
  if ! rec=$(printf '%s\n' "$json" | jq -c --arg p "$token" \
    '[.[] | select(.sessionId | startswith($p))][0] // empty' 2>/dev/null); then
    echo "query-failed"
    return 4
  fi
  if [[ -z "$rec" ]]; then
    echo "not-listed"
    return 3
  fi

  local status state
  status=$(printf '%s\n' "$rec" | jq -r '.status // "-"')
  state=$(printf '%s\n' "$rec" | jq -r '.state // "-"')

  # The observed (status, state) matrix — see the header table. Liveness
  # lives in `status`, terminality in `state` (#581, #591).
  case "${status}/${state}" in
    busy/working|busy/-|-/busy|idle/working)
      # idle/working: v2.1.205 shape (#638) — live session between active
      # turns. idle = not currently in a turn (not terminal), working =
      # session not finished → alive. Same verdict as busy/working.
      echo "alive"
      return 0
      ;;
    blocked/working|blocked/-|idle/blocked|-/blocked)
      echo "blocked"
      return 0
      ;;
    idle/done|-/done)
      echo "done"
      return 0
      ;;
    idle/stopped|-/stopped)
      echo "stopped"
      return 0
      ;;
    *)
      # Schema drift: report it, loudly, without guessing (Rule of
      # Repair — coercing an unknown status to "dead" is how #581
      # killed healthy Workers).
      echo "Warning: unknown (status, state) pair (${status}, ${state})" \
        "for session token ${token} — claude CLI schema drift?" \
        "(ADR-0018: update the matrix in claude-bg.sh," \
        "claude-code-constraints.md, and mock-claude.bash together)" >&2
      echo "unknown-value"
      return 5
      ;;
  esac
}

# claude_bg_token_verdict <token> [extra-args...]
claude_bg_token_verdict() {
  local token="$1"
  shift
  local json
  if ! json=$(claude_bg_agents_json "$@"); then
    echo "query-failed"
    return 4
  fi
  claude_bg_token_verdict_from_json "$json" "$token"
}

# claude_bg_token_alive_from_json <json> <token>
claude_bg_token_alive_from_json() {
  local verdict rc=0
  verdict=$(claude_bg_token_verdict_from_json "$1" "$2") || rc=$?
  case "$rc" in
    0) [[ "$verdict" == "alive" || "$verdict" == "blocked" ]] ;;
    3) return 1 ;;      # not-listed — verifiably not alive
    *) return "$rc" ;;  # query-failed / unknown-value — never coerced
  esac
}

# claude_bg_token_alive <token>
claude_bg_token_alive() {
  local verdict rc=0
  verdict=$(claude_bg_token_verdict "$1") || rc=$?
  case "$rc" in
    0) [[ "$verdict" == "alive" || "$verdict" == "blocked" ]] ;;
    3) return 1 ;;      # not-listed — verifiably not alive
    *) return "$rc" ;;  # query-failed / unknown-value — never coerced
  esac
}

# claude_bg_spawn <cwd> [claude-args...]
claude_bg_spawn() {
  local cwd="${1:?Usage: claude_bg_spawn <cwd> [claude-args...]}"
  shift

  # Launch the session. `claude --bg` returns immediately after printing
  # `backgrounded · <short-id>`; the on-demand daemon supervises it.
  # Claude Code session markers are unset to avoid nested-session
  # detection. Env injection is the caller's responsibility (ADR-0018
  # Decision 3): exported variables reach the daemon only when this call
  # auto-starts it — a pre-existing daemon serves its own env (#589).
  local spawn_out
  spawn_out=$(
    cd "$cwd" && \
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN && \
    claude --bg "$@"
  ) || return 1

  # Parse the human-oriented spawn line solely to extract the short-ID
  # token — structured data comes from `agents --json` (capture below).
  local short_id
  short_id=$(printf '%s\n' "$spawn_out" | awk '/backgrounded/ {print $NF; exit}')
  [[ "$short_id" =~ ^[0-9a-f]{8}$ ]] || short_id=""
  echo "$short_id"
}

# claude_bg_stop <token>
claude_bg_stop() {
  local token="${1:-}"
  [[ -n "$token" ]] || return 0

  # `claude stop` accepts only the short 8-char job ID (first 8 hex chars
  # of the sessionId). Full UUIDs always fail with "No job matching" (#621).
  local job_id="${token:0:8}"
  local stop_err
  if ! stop_err=$(claude stop "$job_id" 2>&1); then
    # Rule of Repair: make stop failure visible — the previous || true
    # silently swallowed every failure, hiding #621 for weeks.
    echo "Warning: claude stop '${job_id}' failed: ${stop_err}" >&2
  fi
  return 0
}

# claude_bg_wait_terminal <token> <interval> <timeout>
claude_bg_wait_terminal() {
  local token="${1:?Usage: claude_bg_wait_terminal <token> <interval> <timeout>}"
  local interval="${2:?Usage: claude_bg_wait_terminal <token> <interval> <timeout>}"
  local timeout="${3:?Usage: claude_bg_wait_terminal <token> <interval> <timeout>}"

  # Wall-clock deadline via SECONDS: safe with interval=0 (no elapsed
  # arithmetic that would never advance).
  local deadline=$((SECONDS + timeout))
  local verdict
  while :; do
    # --all keeps finished sessions visible across a daemon restart.
    # not-listed / query-failed (daemon restart window) and unknown-value
    # (drift ≠ termination) are transient here — keep polling.
    verdict=$(claude_bg_token_verdict "$token" --all) || verdict=""
    case "$verdict" in
      done|stopped|blocked)
        echo "$verdict"
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
