#!/usr/bin/env bash
# spawn-orchestrator.sh — Spawn Orchestrator as independent OS process
#
# Usage: spawn-orchestrator.sh <prompt>
#
# Launches the Orchestrator agent as a background `claude -p` process
# in the current repository's main working tree. Unlike Workers, the
# Orchestrator does not need its own worktree, FIFO, or state management —
# it is the managing process, not a managed one.
#
# Environment:
#   CEKERNEL_SESSION_ID — Session identifier (required, set by skill)
#   CEKERNEL_ENV — Environment profile (default: default)
#   CEKERNEL_AGENT_ORCHESTRATOR — Agent name (default: orchestrator)
#
# Output: PID of spawned Orchestrator process (stdout)
# Exit codes:
#   0 — Orchestrator spawned successfully
#   1 — General error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"

PROMPT="${1:?Usage: spawn-orchestrator.sh <prompt>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Resolve agent name ──
AGENT_NAME="${CEKERNEL_AGENT_ORCHESTRATOR:-orchestrator}"

# ── Compute cekernel script paths for Orchestrator PATH ──
CEKERNEL_ORCHESTRATOR_SCRIPTS="$(cd "${SCRIPT_DIR}/../orchestrator" && pwd)"
CEKERNEL_PROCESS_SCRIPTS="$(cd "${SCRIPT_DIR}/../process" && pwd)"
CEKERNEL_SHARED_SCRIPTS="$(cd "${SCRIPT_DIR}/../shared" && pwd)"

# ── Launch Orchestrator as background process ──
# Unset Claude Code session markers to avoid nested-session detection.
# Export cekernel env vars so the Orchestrator's Bash tool calls inherit them.
# stdout/stderr discarded — analysis uses transcripts.
(
  cd "$REPO_ROOT" && \
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN && \
  export CEKERNEL_SESSION_ID="${CEKERNEL_SESSION_ID}" && \
  export CEKERNEL_IPC_DIR="${CEKERNEL_IPC_DIR}" && \
  export CEKERNEL_ENV="${CEKERNEL_ENV}" && \
  export PATH="${CEKERNEL_ORCHESTRATOR_SCRIPTS}:${CEKERNEL_PROCESS_SCRIPTS}:${CEKERNEL_SHARED_SCRIPTS}:${PATH}" && \
  exec claude -p --agent "$AGENT_NAME" "$PROMPT"
) >/dev/null 2>&1 &
PID=$!

# Record spawn marker for post-mortem transcript discovery.
# transcript-locator.sh checks orchestrator.spawned to decide
# whether to use agentSetting-based scan for claude -p transcripts.
date +%s > "${CEKERNEL_IPC_DIR}/orchestrator.spawned"

echo "Orchestrator spawned: PID=${PID}, agent=${AGENT_NAME}, session=${CEKERNEL_SESSION_ID}" >&2
echo "$PID"
