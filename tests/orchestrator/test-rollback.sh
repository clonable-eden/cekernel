#!/usr/bin/env bash
# test-rollback.sh — Tests for spawn-worker.sh rollback function
#
# spawn-worker.sh cannot be run directly due to terminal/backend dependency.
# Here we extract and test the rollback() function logic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: rollback"

# Test session
export CEKERNEL_SESSION_ID="test-rollback-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/claude-json-helper.sh"
source "${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"

# ── Create temporary Git repository for testing ──
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

FAKE_REPO="${TEST_TMP}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "initial" --quiet

# Temporary ~/.claude.json for testing
FAKE_CLAUDE_JSON="${TEST_TMP}/claude.json"
export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"

# ── Extract and redefine rollback function from spawn-worker.sh ──
# Mock wezterm (not available in CI)
wezterm() { return 0; }
export -f wezterm

# Source the rollback function (same logic as spawn-worker.sh)
# We test the rollback() defined in spawn-worker.sh directly,
# using the same variable names and logic here.
source_rollback() {
  # Extract only the rollback function from spawn.sh
  # This assumes it matches the rollback() in spawn.sh
  local script="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
  # Extract and eval the rollback function
  local func_body
  func_body=$(sed -n '/^rollback()/,/^}/p' "$script")
  if [[ -z "$func_body" ]]; then
    echo "  FAIL: rollback() function not found in spawn.sh" >&2
    return 1
  fi
  eval "$func_body"
}

# ── Setup: Ensure clean state ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Test 1: All resources exist → rollback cleans up everything ──
(
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"
  # Source backend adapter for rollback (uses backend_kill_worker)
  export CEKERNEL_BACKEND=wezterm
  source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

  # cd so git commands operate on the correct repo
  cd "$FAKE_REPO"

  # Create resources
  ISSUE_NUMBER="100"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  BRANCH="issue/100-test-rollback"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  mkdir -p "$WORKTREE_DIR"
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet

  FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
  mkfifo "$FIFO"

  LOG_DIR="${CEKERNEL_IPC_DIR}/logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/worker-${ISSUE_NUMBER}.log"
  echo "test log" > "$LOG_FILE"

  echo "fake-pane-id" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE_NUMBER}"

  # Register trust
  register_trust "$WORKTREE"

  # Get and execute rollback function
  source_rollback
  rollback 2>/dev/null

  # Verify
  assert_not_exists "FIFO removed after rollback" "$FIFO"
  assert_not_exists "Handle file removed after rollback" "${CEKERNEL_IPC_DIR}/handle-${ISSUE_NUMBER}"
  assert_not_exists "Worktree removed after rollback" "$WORKTREE"
  assert_not_exists "Log file removed after rollback" "$LOG_FILE"

  # Verify trust is unregistered
  if [[ -f "$CLAUDE_JSON" ]]; then
    TRUST=$(jq -r ".projects[\"${WORKTREE}\"] // \"null\"" "$CLAUDE_JSON")
    assert_eq "Trust unregistered after rollback" "null" "$TRUST"
  else
    echo "  PASS: Trust unregistered after rollback (file removed)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi

  # Verify branch is deleted
  if git -C "$FAKE_REPO" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    echo "  FAIL: Branch still exists after rollback"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo "  PASS: Branch deleted after rollback"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi

  report_results
)

# ── Test 2: Partial resources (FIFO only) → rollback without error ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"
rm -f "$FAKE_CLAUDE_JSON"

(
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"
  export CEKERNEL_BACKEND=wezterm
  source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

  # Create only FIFO (worktree, handle not created)
  ISSUE_NUMBER="101"
  FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
  mkfifo "$FIFO"

  # WORKTREE, BRANCH remain undefined

  source_rollback
  rollback 2>/dev/null

  assert_not_exists "FIFO removed in partial rollback" "$FIFO"

  report_results
)

# ── Test 3: No resources exist → rollback without error ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

(
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"
  export CEKERNEL_BACKEND=wezterm
  source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

  ISSUE_NUMBER="102"
  # Create nothing

  source_rollback
  rollback 2>/dev/null
  RESULT=$?

  assert_eq "Rollback with no resources exits cleanly" "0" "$RESULT"

  report_results
)

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"
