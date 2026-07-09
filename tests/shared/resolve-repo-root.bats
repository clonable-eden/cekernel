#!/usr/bin/env bats
# resolve-repo-root.bats — bats-core tests for scripts/shared/resolve-repo-root.sh
#
# Verifies that _strip_worktree_path correctly resolves the real repo root
# even when CWD is inside a .worktrees/ directory.

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RESOLVE_SCRIPT="${CEKERNEL_DIR}/scripts/shared/resolve-repo-root.sh"
}

@test "_strip_worktree_path strips .worktrees/issue/ suffix" {
  local result
  result=$(source "$RESOLVE_SCRIPT"; _strip_worktree_path "/path/to/repo/.worktrees/issue/42-add-widget-support")
  assert_eq "stripped" "/path/to/repo" "$result"
}

@test "_strip_worktree_path leaves normal path unchanged" {
  local result
  result=$(source "$RESOLVE_SCRIPT"; _strip_worktree_path "/path/to/repo")
  assert_eq "unchanged" "/path/to/repo" "$result"
}

@test "_strip_worktree_path handles doubly nested worktree path" {
  local result
  result=$(source "$RESOLVE_SCRIPT"; _strip_worktree_path "/Users/alice/git/repo/.worktrees/issue/439-xxx/.worktrees/issue/439-xxx")
  assert_eq "resolves to repo root" "/Users/alice/git/repo" "$result"
}

@test "_strip_worktree_path handles trailing slash" {
  local result
  result=$(source "$RESOLVE_SCRIPT"; _strip_worktree_path "/path/to/repo/.worktrees/issue/42-foo/")
  assert_eq "trailing slash stripped" "/path/to/repo" "$result"
}

@test ".worktrees in repo name (not as worktree dir) is unchanged" {
  local result
  result=$(source "$RESOLVE_SCRIPT"; _strip_worktree_path "/path/to/.worktrees-project/src")
  assert_eq "unchanged" "/path/to/.worktrees-project/src" "$result"
}
