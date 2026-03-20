#!/usr/bin/env bash
# resolve-repo-root.sh — Resolve the real repo root, even from within a worktree
#
# Usage: source resolve-repo-root.sh
#
# Functions:
#   resolve_repo_root         — Return the real repo root (git rev-parse + worktree strip)
#   _strip_worktree_path PATH — Strip .worktrees/... suffix from a path (pure string op)
#
# Problem:
#   When CWD is inside a .worktrees/ directory, `git rev-parse --show-toplevel`
#   returns the worktree root, not the main repo root. This causes path doubling:
#     /repo/.worktrees/issue/42-foo → WORKTREE_DIR = /repo/.worktrees/issue/42-foo/.worktrees
#
# Solution:
#   After git rev-parse, strip everything from the first `/.worktrees/` onward.

_strip_worktree_path() {
  local path="${1:?Usage: _strip_worktree_path <path>}"
  # Remove trailing slash
  path="${path%/}"
  # Strip from first /.worktrees/ onward (handles doubly nested paths too)
  if [[ "$path" == *"/.worktrees/"* ]]; then
    path="${path%%/.worktrees/*}"
  fi
  echo "$path"
}

resolve_repo_root() {
  local raw_root
  raw_root="$(git rev-parse --show-toplevel)"
  _strip_worktree_path "$raw_root"
}
