#!/usr/bin/env bash
# test-spawn-cwd-drift.sh — Tests for CWD drift protection in spawn scripts
#
# Verifies that orchestrator scripts use resolve_repo_root() instead of raw
# git rev-parse --show-toplevel, preventing .worktrees/ path doubling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-cwd-drift"

# ── Test 1: spawn.sh sources resolve-repo-root.sh ──
SPAWN_CONTENT=$(cat "${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh")
if echo "$SPAWN_CONTENT" | grep -q 'resolve-repo-root.sh'; then
  echo "  PASS: spawn.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: spawn.sh uses resolve_repo_root (not raw git rev-parse) ──
if echo "$SPAWN_CONTENT" | grep -q 'resolve_repo_root'; then
  echo "  PASS: spawn.sh uses resolve_repo_root"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should use resolve_repo_root"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: spawn.sh does NOT use raw git rev-parse --show-toplevel for REPO_ROOT ──
if echo "$SPAWN_CONTENT" | grep -q 'REPO_ROOT=.*git rev-parse --show-toplevel'; then
  echo "  FAIL: spawn.sh should not use raw git rev-parse --show-toplevel for REPO_ROOT"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: spawn.sh does not use raw git rev-parse for REPO_ROOT"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 4: cleanup-worktree.sh sources resolve-repo-root.sh ──
CLEANUP_CONTENT=$(cat "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh")
if echo "$CLEANUP_CONTENT" | grep -q 'resolve-repo-root.sh'; then
  echo "  PASS: cleanup-worktree.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: cleanup-worktree.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: cleanup-worktree.sh uses resolve_repo_root ──
if echo "$CLEANUP_CONTENT" | grep -q 'resolve_repo_root'; then
  echo "  PASS: cleanup-worktree.sh uses resolve_repo_root"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: cleanup-worktree.sh should use resolve_repo_root"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: spawn-orchestrator.sh sources resolve-repo-root.sh ──
SO_CONTENT=$(cat "${CEKERNEL_DIR}/scripts/orchestrator/spawn-orchestrator.sh")
if echo "$SO_CONTENT" | grep -q 'resolve-repo-root.sh'; then
  echo "  PASS: spawn-orchestrator.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-orchestrator.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: process-status.sh sources resolve-repo-root.sh ──
PS_CONTENT=$(cat "${CEKERNEL_DIR}/scripts/orchestrator/process-status.sh")
if echo "$PS_CONTENT" | grep -q 'resolve-repo-root.sh'; then
  echo "  PASS: process-status.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: process-status.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: notify-complete.sh sources resolve-repo-root.sh ──
NC_CONTENT=$(cat "${CEKERNEL_DIR}/scripts/process/notify-complete.sh")
if echo "$NC_CONTENT" | grep -q 'resolve-repo-root.sh'; then
  echo "  PASS: notify-complete.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: notify-complete.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: orchestrator.md documents CWD convention ──
ORCH_MD=$(cat "${CEKERNEL_DIR}/agents/orchestrator.md")
if echo "$ORCH_MD" | grep -q 'CWD Convention'; then
  echo "  PASS: orchestrator.md documents CWD Convention"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: orchestrator.md should document CWD Convention"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: orchestrator.md recommends git -C ──
if echo "$ORCH_MD" | grep -q 'git -C'; then
  echo "  PASS: orchestrator.md recommends git -C"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: orchestrator.md should recommend git -C"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 11: _strip_worktree_path correctly handles the exact reproduction case ──
source "${CEKERNEL_DIR}/scripts/shared/resolve-repo-root.sh"
RESULT=$(_strip_worktree_path "/path/to/repo/.worktrees/issue/439-xxx")
assert_eq "reproduction case: spawn from drifted CWD" "/path/to/repo" "$RESULT"

report_results
