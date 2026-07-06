#!/usr/bin/env bash
# spawn-orchestrator.sh — Spawn Orchestrator as a `claude --bg` background session
#
# Usage: spawn-orchestrator.sh <prompt>
#
# Launches the Orchestrator agent as a `claude --bg` background agent
# session in the current repository's main working tree (ADR-0016 Phase 2).
# The on-demand daemon owns and supervises the process; cekernel captures
# the daemon-assigned session ID and persists it deterministically to
# ${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id at spawn time — this
# replaces both orchestrator.pid liveness management and the post-startup
# discovery heuristic that mis-attributed concurrent sessions (#571).
#
# Unlike Workers, the Orchestrator does not need its own worktree, FIFO,
# or state management — it is the managing process, not a managed one.
#
# Environment:
#   CEKERNEL_SESSION_ID — Session identifier (required, set by skill)
#   CEKERNEL_ENV — Environment profile (default: default)
#   CEKERNEL_AGENT_ORCHESTRATOR — Agent name (default: orchestrator)
#
# Output: captured Claude Code session token (stdout) — the full session
#   UUID, or the short ID (first 8 hex chars) as a degraded fallback
# Exit codes:
#   0 — Orchestrator spawned successfully
#   1 — General error (spawn or session-ID capture failed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/resolve-repo-root.sh"
source "${SCRIPT_DIR}/../shared/bare-mode.sh"
source "${SCRIPT_DIR}/../shared/claude-bg.sh"
source "${SCRIPT_DIR}/../shared/claude-session-id.sh"

PROMPT="${1:?Usage: spawn-orchestrator.sh <prompt>}"
REPO_ROOT="$(resolve_repo_root)"

# --bare is conditional on auth availability (ADR-0016 Amendment 1):
# bare_mode_prepare drops --bare (OAuth/keychain auth) with a stderr notice
# when no bare-compatible auth path exists — interactive spawn paths branch
# instead of hard-failing.
bare_mode_prepare "$REPO_ROOT"

# ── Resolve agent name ──
AGENT_NAME="${CEKERNEL_AGENT_ORCHESTRATOR:-orchestrator}"

# ── Compute cekernel script paths for Orchestrator PATH ──
CEKERNEL_ORCHESTRATOR_SCRIPTS="$(cd "${SCRIPT_DIR}/../orchestrator" && pwd)"
CEKERNEL_PROCESS_SCRIPTS="$(cd "${SCRIPT_DIR}/../process" && pwd)"
CEKERNEL_SHARED_SCRIPTS="$(cd "${SCRIPT_DIR}/../shared" && pwd)"

# ── Launch Orchestrator as a background agent session ──
# `claude --bg` returns immediately after printing `backgrounded ·
# <short-id>`; the on-demand daemon supervises the session.
# Unset Claude Code session markers to avoid nested-session detection.
# The env exports are best-effort under --bg: they reach the session only
# when this call auto-starts the daemon (a pre-existing daemon keeps its
# own environment) — the reliable channel for CEKERNEL_* values is the
# prompt, which the orchestrate/dispatch skills populate.
# CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 stays for now: under --bg an
# auto-detached Bash call no longer kills the process (#558), but whether
# a background-task completion re-invokes a `done` session is unverified —
# without re-invocation the Orchestrator would stall silently.
# stderr discarded — analysis uses transcripts; stdout is parsed for the
# short-ID token only (structured data comes from `agents --json`).
SPAWN_OUT=$(
  cd "$REPO_ROOT" && \
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN && \
  export CEKERNEL_SESSION_ID="${CEKERNEL_SESSION_ID}" && \
  export CEKERNEL_IPC_DIR="${CEKERNEL_IPC_DIR}" && \
  export CEKERNEL_ENV="${CEKERNEL_ENV}" && \
  export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 && \
  export PATH="${CEKERNEL_ORCHESTRATOR_SCRIPTS}:${CEKERNEL_PROCESS_SCRIPTS}:${CEKERNEL_SHARED_SCRIPTS}:${PATH}" && \
  claude --bg "${CEKERNEL_BARE_FLAGS[@]}" --agent "$AGENT_NAME" "$PROMPT" 2>/dev/null
) || {
  echo "Error: claude --bg spawn failed for Orchestrator" >&2
  exit 1
}

# ── Capture the daemon-assigned session ID (ADR-0016 normative order) ──
# Primary: short ID from the human-oriented spawn line, prefix-matched
# against agents --json. Fallback: newest background session at the
# repo-root cwd (kind filter excludes interactive sessions — #571).
SHORT_ID=$(printf '%s\n' "$SPAWN_OUT" | awk '/backgrounded/ {print $NF; exit}')
[[ "$SHORT_ID" =~ ^[0-9a-f]{8}$ ]] || SHORT_ID=""

# agents --json reports realpath'd cwd (e.g. /tmp → /private/tmp)
CWD_REAL=$(cd "$REPO_ROOT" && pwd -P)

if ! CLAUDE_SESSION_ID=$(claude_bg_capture_session_id "$SHORT_ID" "$CWD_REAL"); then
  if [[ -n "$SHORT_ID" ]]; then
    # Degraded: the short ID is a usable prefix token (liveness/stop work),
    # but transcript direct lookup needs the full UUID — warn, don't fail.
    echo "Warning: could not resolve full session UUID for Orchestrator;" \
      "using short ID ${SHORT_ID}" >&2
    CLAUDE_SESSION_ID="$SHORT_ID"
  else
    echo "Error: session-ID capture failed for Orchestrator" \
      "(no short ID in spawn output, no matching background session)" >&2
    exit 1
  fi
fi

# Persist the captured token for orchctl count/ps/gc liveness and
# post-mortem transcript discovery (deterministic — #571).
claude_session_id_persist "$CLAUDE_SESSION_ID"

# Record spawn marker for elapsed display and post-mortem transcript
# discovery (transcript-locator.sh checks orchestrator.spawned to decide
# whether to use agentSetting-based scan).
date +%s > "${CEKERNEL_IPC_DIR}/orchestrator.spawned"

echo "Orchestrator spawned: claude-session=${CLAUDE_SESSION_ID}, agent=${AGENT_NAME}, session=${CEKERNEL_SESSION_ID}" >&2
echo "$CLAUDE_SESSION_ID"
