#!/usr/bin/env bash
# test-spawn-retry.sh — Tests for stale worktree/branch handling on spawn-worker.sh retry
#
# Verifies that stale worktrees/branches left from a previous failed spawn
# are cleaned up before recreating.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-retry"

# ── Create temporary Git repository for testing ──
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

FAKE_REPO="${TEST_TMP}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "initial" --quiet

# ── Extract cleanup_stale_worktree function from spawn-worker.sh ──
source_cleanup_stale() {
  local script="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
  local func_body
  func_body=$(sed -n '/^cleanup_stale_worktree()/,/^}/p' "$script")
  if [[ -z "$func_body" ]]; then
    echo "  FAIL: cleanup_stale_worktree() function not found in spawn.sh" >&2
    return 1
  fi
  eval "$func_body"
}

# ── Test 1: Stale worktree + branch exist → cleanup → recreate succeeds ──
echo ""
echo "  Test 1: stale worktree + branch cleanup"
(
  cd "$FAKE_REPO"

  BRANCH="issue/200-stale-retry"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # Create stale state (simulate previous failure)
  mkdir -p "$WORKTREE_DIR"
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet

  # Verify worktree and branch exist
  assert_dir_exists "Stale worktree exists before cleanup" "$WORKTREE"
  assert_file_exists "Stale worktree has .git file" "${WORKTREE}/.git"

  # Run cleanup_stale_worktree
  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH"

  # Verify recreation succeeds after cleanup
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  assert_dir_exists "Worktree recreated after cleanup" "$WORKTREE"

  # Teardown
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true

  report_results
)

# ── Test 2: Stale branch only (worktree already rolled back) → recreate succeeds ──
echo ""
echo "  Test 2: stale branch only cleanup"
(
  cd "$FAKE_REPO"

  BRANCH="issue/201-branch-only"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # Create only branch (worktree rollback succeeded but branch deletion failed)
  mkdir -p "$WORKTREE_DIR"
  git branch "$BRANCH" HEAD

  # Verify branch exists
  git rev-parse --verify "$BRANCH" >/dev/null 2>&1
  assert_eq "Stale branch exists" "0" "$?"

  # Run cleanup_stale_worktree
  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH"

  # Verify recreation succeeds after cleanup
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  assert_dir_exists "Worktree created after branch cleanup" "$WORKTREE"

  # Teardown
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true

  report_results
)

# ── Test 3: No stale resources → completes without error ──
echo ""
echo "  Test 3: no stale resources"
(
  cd "$FAKE_REPO"

  BRANCH="issue/202-clean-state"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # Don't create any stale resources
  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH" 2>/dev/null
  RESULT=$?

  assert_eq "No stale resources exits cleanly" "0" "$RESULT"

  report_results
)

# ── Test 4: Orphaned worktree directory (not registered in git worktree list) ──
echo ""
echo "  Test 4: orphaned worktree directory"
(
  cd "$FAKE_REPO"

  BRANCH="issue/203-orphan-dir"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # Create worktree then remove via git (directory removed by git)
  mkdir -p "$WORKTREE_DIR"
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  git worktree remove --force "$WORKTREE"
  # Branch remains after remove
  # Manually recreate directory to simulate orphan state
  mkdir -p "$WORKTREE"

  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH"

  # Verify orphan directory is deleted and recreation succeeds
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  assert_dir_exists "Worktree created after orphan cleanup" "$WORKTREE"

  # Teardown
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true

  report_results
)
