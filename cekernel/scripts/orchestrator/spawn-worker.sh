#!/usr/bin/env bash
# spawn-worker.sh — Create worktree + launch Worker in terminal window
#
# Usage: spawn-worker.sh <issue-number> [base-branch]
# Output: FIFO path (stdout last line)
# Exit codes:
#   0 — Worker spawned successfully
#   1 — General error
#   2 — Max concurrent workers reached (CEKERNEL_MAX_WORKERS)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
source "${SCRIPT_DIR}/../shared/terminal-adapter.sh"

ISSUE_NUMBER="${1:?Usage: spawn-worker.sh <issue-number> [base-branch]}"
BASE_BRANCH="${2:-main}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Concurrency Guard ──
MAX_WORKERS="${CEKERNEL_MAX_WORKERS:-3}"

active_worker_count() {
  find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | wc -l | tr -d ' '
}

mkdir -p "$CEKERNEL_IPC_DIR"
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_WORKERS" ]]; then
  echo "Error: max workers ($MAX_WORKERS) reached (active: $ACTIVE). Waiting..." >&2
  exit 2
fi

# ── Fetch issue info ──
ISSUE_TITLE=$(gh issue view "$ISSUE_NUMBER" --json title -q '.title')
[[ -n "$ISSUE_TITLE" ]] || { echo "Error: issue #${ISSUE_NUMBER} not found" >&2; exit 1; }

# ── Branch name / path generation ──
# Default naming convention. If the target repository has its own convention,
# the Worker may rename the branch (cekernel does not enforce branch names).
SLUG=$(echo "$ISSUE_TITLE" \
  | sed 's/[^a-zA-Z0-9]/-/g' \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -c1-40)
BRANCH="issue/${ISSUE_NUMBER}-${SLUG}"
WORKTREE_DIR="${REPO_ROOT}/.worktrees"
WORKTREE="${WORKTREE_DIR}/${BRANCH}"

# ── Rollback: clean up resources on failure ──
rollback() {
  echo "Error: spawn-worker.sh failed. Rolling back..." >&2
  # Kill terminal pane
  if [[ -n "${MAIN_PANE:-}" ]]; then
    terminal_kill_pane "$MAIN_PANE"
  fi
  rm -f "${CEKERNEL_IPC_DIR}/pane-${ISSUE_NUMBER}"
  # Unregister trust
  if [[ -n "${WORKTREE:-}" && -d "${WORKTREE:-}" ]]; then
    unregister_trust "$WORKTREE" 2>/dev/null || true
  fi
  # Remove worktree
  if [[ -n "${WORKTREE:-}" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || true
  fi
  # Delete branch
  if [[ -n "${BRANCH:-}" ]]; then
    git branch -D "$BRANCH" 2>/dev/null || true
  fi
  # Delete log file
  rm -f "${LOG_FILE:-}"
  rmdir "${LOG_DIR:-}" 2>/dev/null || true
  # Delete FIFO
  rm -f "${FIFO:-}"
}
trap rollback ERR

# ── Create FIFO (named pipe) ──
mkdir -p "$CEKERNEL_IPC_DIR"
FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
[[ -p "$FIFO" ]] || mkfifo "$FIFO"

# ── Create log file ──
LOG_DIR="${CEKERNEL_IPC_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/worker-${ISSUE_NUMBER}.log"

# ── Stale worktree/branch cleanup (retry safety) ──
# If a previous spawn failure + incomplete rollback left stale worktree or branch,
# clean them up before creating new ones.
cleanup_stale_worktree() {
  local worktree="$1" branch="$2"
  # Registered as git worktree (.git file holds worktree reference)
  if [[ -f "${worktree}/.git" ]]; then
    echo "Warning: stale worktree found at ${worktree}, removing..." >&2
    git worktree remove --force "$worktree" 2>/dev/null || true
  fi
  # Not registered in git worktree list, but directory still exists
  if [[ -d "$worktree" ]]; then
    echo "Warning: orphaned worktree directory found at ${worktree}, removing..." >&2
    rm -rf "$worktree"
    git worktree prune 2>/dev/null || true
  fi
  # Delete stale branch
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "Warning: stale branch found: ${branch}, deleting..." >&2
    git branch -D "$branch" 2>/dev/null || true
  fi
}

# ── Create worktree ──
mkdir -p "$WORKTREE_DIR"
git fetch origin "${BASE_BRANCH}" --quiet
cleanup_stale_worktree "$WORKTREE" "$BRANCH"
git worktree add -b "$BRANCH" "$WORKTREE" "origin/${BASE_BRANCH}"

# ── Register trust (so Worker can start without trust prompt) ──
register_trust "$WORKTREE"

echo "worktree: $WORKTREE" >&2
echo "branch:   $BRANCH" >&2

# ── Launch terminal window (project_layout equivalent) ──
#
#   ┌──────────────┬──────────┐
#   │  Claude Code │ Terminal │
#   │   (60%)      │  (40%)   │
#   ├──────────────┴──────────┤
#   │  git log (25%)          │
#   └─────────────────────────┘

# Propagate CEKERNEL_SESSION_ID to Worker
# Create Worker in the same workspace as Orchestrator
WORKSPACE=$(terminal_resolve_workspace)

# Launch Claude Code in main pane
# Initial prompt for Worker:
# 1. Read the target repository's CLAUDE.md first
# 2. Follow kernel's protocol only for lifecycle (PR → CI → merge → notify)
# 3. Follow the target repository's conventions for implementation
PROMPT="Resolve issue #${ISSUE_NUMBER}. First read the target repository's CLAUDE.md and fully follow its conventions. Follow only the kernel Worker Protocol for lifecycle: implement → create PR → verify CI → merge. When done, run ${CLAUDE_PLUGIN_ROOT}/scripts/worker/notify-complete.sh ${ISSUE_NUMBER} merged <pr-number>."

# Build JSON payload for Lua-side layout construction.
# The wezterm.lua user-var-changed handler creates the 3-pane layout in-process,
# reducing 7+ wezterm cli IPC calls to 3. See docs/wezterm-events.lua.
LAYOUT_PAYLOAD=$(cat <<EOJSON
{"worktree":"${WORKTREE}","session_id":"${CEKERNEL_SESSION_ID}","prompt":"claude --agent cekernel:worker '${PROMPT}'","issue_number":"${ISSUE_NUMBER}"}
EOJSON
)

MAIN_PANE=$(terminal_spawn_worker_layout "$WORKTREE" "$WORKSPACE" "$LAYOUT_PAYLOAD")

# Save pane ID (used by health-check / cleanup)
echo "$MAIN_PANE" > "${CEKERNEL_IPC_DIR}/pane-${ISSUE_NUMBER}"

# ── Record lifecycle event in log ──
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SPAWN issue=#${ISSUE_NUMBER} branch=${BRANCH}" >> "$LOG_FILE"

echo "session: $CEKERNEL_SESSION_ID" >&2
echo "worker spawned: issue #${ISSUE_NUMBER}" >&2

# Return FIFO path (used by orchestrator for reading)
echo "$FIFO"
