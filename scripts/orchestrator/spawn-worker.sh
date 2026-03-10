#!/usr/bin/env bash
# spawn-worker.sh — Create worktree + launch Worker via backend
#
# Usage: spawn-worker.sh [--resume] [--priority <priority>] <issue-number> [base-branch]
#   priority: critical|high|normal|low or numeric 0-19 (default: normal)
# Output: FIFO path (stdout last line)
# Options:
#   --resume    Resume a suspended Worker (reuse existing worktree)
#   --priority  Set worker priority (nice value)
# Exit codes:
#   0 — Worker spawned successfully
#   1 — General error
#   2 — Max concurrent workers reached (CEKERNEL_MAX_WORKERS)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEKERNEL_AGENT_WORKER="${CEKERNEL_AGENT_WORKER:-worker}"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
source "${SCRIPT_DIR}/../shared/backend-adapter.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/worker-priority.sh"
source "${SCRIPT_DIR}/../shared/task-file.sh"
source "${SCRIPT_DIR}/../shared/checkpoint-file.sh"
source "${SCRIPT_DIR}/../shared/issue-lock.sh"

# ── Flag parsing ──
RESUME=0
PRIORITY="normal"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume) RESUME=1; shift ;;
    --priority) PRIORITY="${2:?--priority requires a value}"; shift 2 ;;
    *) break ;;
  esac
done

ISSUE_NUMBER="${1:?Usage: spawn-worker.sh [--resume] [--priority <priority>] <issue-number> [base-branch]}"
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

# ── Issue Lock (duplicate Worker prevention) ──
if ! issue_lock_acquire "$REPO_ROOT" "$ISSUE_NUMBER"; then
  echo "Error: issue #${ISSUE_NUMBER} is already being processed by another Worker." >&2
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
  # Kill Worker via backend (handle file managed internally)
  backend_kill_worker "$ISSUE_NUMBER" 2>/dev/null || true
  rm -f "${CEKERNEL_IPC_DIR}/handle-${ISSUE_NUMBER}"
  # In resume mode, do not destroy the existing worktree/branch
  if [[ "${RESUME:-0}" -eq 0 ]]; then
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
  fi
  # Delete payload file (wezterm backend: avoids send-text 1024-byte limit)
  rm -f "${CEKERNEL_IPC_DIR}/payload-${ISSUE_NUMBER}.b64"
  # Delete log file
  rm -f "${LOG_FILE:-}"
  rmdir "${LOG_DIR:-}" 2>/dev/null || true
  # Delete FIFO, state file, and priority file
  rm -f "${FIFO:-}"
  rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.state"
  rm -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.priority"
  # Release issue lock
  if [[ -n "${REPO_ROOT:-}" ]]; then
    issue_lock_release "$REPO_ROOT" "$ISSUE_NUMBER"
  fi
}
trap rollback ERR

# ── Create FIFO (named pipe) ──
mkdir -p "$CEKERNEL_IPC_DIR"
FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
[[ -p "$FIFO" ]] || mkfifo "$FIFO"

# ── State: NEW (Worker spawned, worktree being created) ──
worker_state_write "$ISSUE_NUMBER" NEW "spawning"

# ── Priority: Set worker nice value ──
worker_priority_write "$ISSUE_NUMBER" "$PRIORITY"

# ── Create log file ──
LOG_DIR="${CEKERNEL_IPC_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/worker-${ISSUE_NUMBER}.log"

# ── Log FIFO creation ──
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FIFO_CREATE issue=#${ISSUE_NUMBER} path=${FIFO}" >> "$LOG_FILE"

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

# ── Create or reuse worktree ──
if [[ "$RESUME" -eq 1 ]]; then
  # Resume mode: reuse existing worktree (must already exist)
  if [[ ! -d "$WORKTREE" ]]; then
    echo "Error: worktree not found for resume: ${WORKTREE}" >&2
    echo "Cannot resume without an existing worktree." >&2
    exit 1
  fi
  echo "resume: reusing worktree $WORKTREE" >&2

  # Re-register trust (may have been cleaned up)
  register_trust "$WORKTREE"

  # Verify checkpoint exists for resume
  if checkpoint_file_exists "$WORKTREE"; then
    echo "checkpoint: $(checkpoint_file_path "$WORKTREE")" >&2
  else
    echo "Warning: no checkpoint file found. Worker will start fresh." >&2
  fi
else
  # Normal mode: create new worktree
  mkdir -p "$WORKTREE_DIR"
  git fetch origin "${BASE_BRANCH}" --quiet
  cleanup_stale_worktree "$WORKTREE" "$BRANCH"
  git worktree add -b "$BRANCH" "$WORKTREE" "origin/${BASE_BRANCH}"

  # Register trust (so Worker can start without trust prompt)
  register_trust "$WORKTREE"

  # Extract issue data into worktree (session memory: page cache)
  # Workers read .cekernel-task.md locally instead of calling gh issue view,
  # reducing GitHub API calls and context window consumption.
  create_task_file "$WORKTREE" "$ISSUE_NUMBER"
  echo "task file: $(task_file_path "$WORKTREE")" >&2
fi

echo "worktree: $WORKTREE" >&2
echo "branch:   $BRANCH" >&2

# ── Compute cekernel script paths for Worker PATH ──
CEKERNEL_WORKER_SCRIPTS="$(cd "${SCRIPT_DIR}/../worker" && pwd)"
CEKERNEL_SHARED_SCRIPTS="$(cd "${SCRIPT_DIR}/../shared" && pwd)"

# ── Write .cekernel-env to worktree ──
# Instead of embedding a 200+ char export string in the prompt (which LLMs
# can truncate, losing :$PATH and breaking basic commands like wc/grep),
# write env vars to a file and use a short "source .cekernel-env" prefix.
cat > "${WORKTREE}/.cekernel-env" <<EOF
export CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID}
export CEKERNEL_IPC_DIR=${CEKERNEL_IPC_DIR}
export CEKERNEL_ENV=${CEKERNEL_ENV}
export PATH=${CEKERNEL_WORKER_SCRIPTS}:${CEKERNEL_SHARED_SCRIPTS}:\$PATH
EOF

BASH_PREFIX="source .cekernel-env"

# ── Launch Worker via backend ──
# Initial prompt for Worker:
# 1. Read the target repository's CLAUDE.md first
# 2. Follow kernel's protocol only for lifecycle (PR → CI → notify)
# 3. Follow the target repository's conventions for implementation
if [[ "$RESUME" -eq 1 ]]; then
  PROMPT="Resume issue #${ISSUE_NUMBER}. Read .cekernel-checkpoint.md to understand previous progress, then continue from where the previous Worker left off. First read the target repository's CLAUDE.md and fully follow its conventions. Follow only the kernel Worker Protocol for lifecycle: implement → create PR → verify CI. When done, run notify-complete.sh ${ISSUE_NUMBER} ci-passed <pr-number>. When executing Bash during processing, always prefix with: ${BASH_PREFIX} &&"
else
  PROMPT="Resolve issue #${ISSUE_NUMBER}. First read the target repository's CLAUDE.md and fully follow its conventions. Follow only the kernel Worker Protocol for lifecycle: implement → create PR → verify CI. When done, run notify-complete.sh ${ISSUE_NUMBER} ci-passed <pr-number>. When executing Bash during processing, always prefix with: ${BASH_PREFIX} &&"
fi

# Backend handles workspace resolution, window spawning, and handle file management internally.
# Callers pass only (issue, worktree, prompt) — the backend decides how to launch.
backend_spawn_worker "$ISSUE_NUMBER" "$WORKTREE" "$PROMPT"

# ── State: READY (Worktree ready, Claude agent starting) ──
worker_state_write "$ISSUE_NUMBER" READY "agent-starting"

# ── Record lifecycle event in log ──
if [[ "$RESUME" -eq 1 ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] RESUME issue=#${ISSUE_NUMBER} branch=${BRANCH} priority=${PRIORITY}" >> "$LOG_FILE"
  echo "session: $CEKERNEL_SESSION_ID" >&2
  echo "worker resumed: issue #${ISSUE_NUMBER}" >&2
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SPAWN issue=#${ISSUE_NUMBER} branch=${BRANCH} priority=${PRIORITY}" >> "$LOG_FILE"
  echo "session: $CEKERNEL_SESSION_ID" >&2
  echo "worker spawned: issue #${ISSUE_NUMBER}" >&2
fi

# Return FIFO path (used by orchestrator for reading)
echo "$FIFO"
