#!/usr/bin/env bash
# worker-stop-guard.sh — Claude Code Stop hook: Worker lifecycle guard
#
# Registered in hooks/hooks.json (plugin Stop hook, ADR-0018, #533).
# Keeps a Worker session running until its lifecycle completes: when the
# session tries to end its turn before notify-complete.sh has recorded
# TERMINATED, the guard returns hookSpecificOutput.additionalContext
# (non-error feedback, Claude Code v2.1.166+) instructing the Worker to
# continue the Worker Protocol. This closes the "Worker dies before the
# completion notification" failure mode (#558 family).
#
# Input:  hook JSON on stdin (cwd, hook_event_name, stop_hook_active, ...)
# Output: nothing (stop allowed), or JSON with
#         hookSpecificOutput.additionalContext (turn continues)
# Exit:   always 0 — the guard is advisory, never a hook error
#
# Worker detection (all read from the hook's cwd, no env dependency —
# hook process env is the session env, which is unreliable under --bg):
#   - ${CEKERNEL_TASK_FILENAME:-.cekernel-task.md} with an `issue:` field
#   - .cekernel-env written by spawn.sh (provides CEKERNEL_IPC_DIR)
# Anything else (interactive sessions, Orchestrators, Reviewer subagent
# worktrees) stays silent: fail-open by design — the guard must never
# disturb non-Worker sessions.
#
# Loop protection: Claude Code caps consecutive Stop-hook continuations
# at 8 per turn boundary, so a Worker that genuinely cannot complete is
# eventually released.
#
# Environment:
#   CEKERNEL_DISABLE_STOP_GUARD — set to 1 to disable the guard entirely
#     (e.g. a human debugging interactively inside a Worker worktree).
set -euo pipefail

# ── Kill switch ──
if [[ "${CEKERNEL_DISABLE_STOP_GUARD:-0}" == "1" ]]; then
  exit 0
fi

INPUT=$(cat)

# ── Parse hook input (fail-open on malformed JSON) ──
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
[[ -n "$CWD" ]] || exit 0
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "Stop"' 2>/dev/null) || EVENT="Stop"

# ── Worker worktree detection ──
TASK_FILE="${CWD}/${CEKERNEL_TASK_FILENAME:-.cekernel-task.md}"
ENV_FILE="${CWD}/.cekernel-env"
[[ -f "$TASK_FILE" && -f "$ENV_FILE" ]] || exit 0

ISSUE=$(awk '/^issue:[[:space:]]*[0-9]+[[:space:]]*$/ { print $2; exit }' "$TASK_FILE")
[[ "$ISSUE" =~ ^[0-9]+$ ]] || exit 0

# ── Locate the Worker state file ──
# Parse (not source) .cekernel-env: the guard runs on every session stop,
# so it must not execute worktree content or mutate its own environment.
IPC_DIR=$(sed -n 's/^export CEKERNEL_IPC_DIR=//p' "$ENV_FILE" | head -1)

STATE="UNKNOWN"
DETAIL=""
if [[ -n "$IPC_DIR" && -f "${IPC_DIR}/worker-${ISSUE}.state" ]]; then
  # Format: STATE:TIMESTAMP:detail (see worker-state.sh)
  STATE_LINE=$(head -1 "${IPC_DIR}/worker-${ISSUE}.state")
  STATE="${STATE_LINE%%:*}"
  [[ -n "$STATE" ]] || STATE="UNKNOWN"
  DETAIL=$(printf '%s' "$STATE_LINE" | cut -d: -f3-)
fi

# ── Completed lifecycle: allow the stop ──
if [[ "$STATE" == "TERMINATED" ]]; then
  exit 0
fi

# ── Incomplete lifecycle: continue the turn with non-error feedback ──
CONTEXT="cekernel Worker lifecycle for issue #${ISSUE} is not complete (state: ${STATE}"
[[ -n "$DETAIL" ]] && CONTEXT="${CONTEXT}, detail: ${DETAIL}"
CONTEXT="${CONTEXT}). Do not end the session yet. Continue the Worker Protocol: \
finish the current phase, verify CI with 'gh pr checks', then run \
'notify-complete.sh ${ISSUE} <result> <detail>'. If the task cannot be \
completed, run 'notify-complete.sh ${ISSUE} failed \"<reason>\"' before stopping."

jq -cn --arg event "$EVENT" --arg context "$CONTEXT" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
exit 0
