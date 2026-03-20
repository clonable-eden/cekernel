#!/usr/bin/env bash
# test-resolve-repo-root.sh — Tests for resolve-repo-root.sh
#
# Verifies that resolve_repo_root() correctly resolves the real repo root
# even when CWD is inside a .worktrees/ directory (CWD drift scenario).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESOLVE_SCRIPT="${CEKERNEL_DIR}/scripts/shared/resolve-repo-root.sh"

echo "test: resolve-repo-root.sh"

# ── Test 1: resolve-repo-root.sh exists ──
assert_file_exists "resolve-repo-root.sh exists" "$RESOLVE_SCRIPT"

# ── Test 2: resolve_repo_root strips .worktrees/ suffix ──
RESULT=$(
  source "$RESOLVE_SCRIPT"
  _strip_worktree_path "/path/to/repo/.worktrees/issue/42-add-widget-support"
)
assert_eq "strips .worktrees/issue/42-... suffix" "/path/to/repo" "$RESULT"

# ── Test 3: resolve_repo_root leaves normal path unchanged ──
RESULT=$(
  source "$RESOLVE_SCRIPT"
  _strip_worktree_path "/path/to/repo"
)
assert_eq "normal path unchanged" "/path/to/repo" "$RESULT"

# ── Test 4: handles deeply nested worktree path ──
RESULT=$(
  source "$RESOLVE_SCRIPT"
  _strip_worktree_path "/Users/alice/git/repo/.worktrees/issue/439-xxx/.worktrees/issue/439-xxx"
)
assert_eq "doubly nested .worktrees/ resolves to repo root" "/Users/alice/git/repo" "$RESULT"

# ── Test 5: handles worktree path with trailing slash ──
RESULT=$(
  source "$RESOLVE_SCRIPT"
  _strip_worktree_path "/path/to/repo/.worktrees/issue/42-foo/"
)
assert_eq "trailing slash stripped" "/path/to/repo" "$RESULT"

# ── Test 6: resolve_repo_root function is defined ──
RESULT=$(
  source "$RESOLVE_SCRIPT"
  type -t resolve_repo_root 2>/dev/null || echo "not found"
)
assert_eq "resolve_repo_root function is defined" "function" "$RESULT"

# ── Test 7: path with .worktrees in repo name (not as worktree dir) is unchanged ──
RESULT=$(
  source "$RESOLVE_SCRIPT"
  _strip_worktree_path "/path/to/.worktrees-project/src"
)
assert_eq ".worktrees in repo name (no /) is unchanged" "/path/to/.worktrees-project/src" "$RESULT"

report_results
