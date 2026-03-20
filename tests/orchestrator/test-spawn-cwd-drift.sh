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

# Helper: grep directly from file to avoid SIGPIPE under set -euo pipefail.
# echo "$large_var" | grep -q causes broken pipe when grep -q exits early.
file_contains() {
  grep -q "$1" "$2"
}

SPAWN_SH="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
CLEANUP_SH="${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh"
SPAWN_ORCH_SH="${CEKERNEL_DIR}/scripts/ctl/spawn-orchestrator.sh"
PROCESS_STATUS_SH="${CEKERNEL_DIR}/scripts/orchestrator/process-status.sh"
NOTIFY_COMPLETE_SH="${CEKERNEL_DIR}/scripts/process/notify-complete.sh"
ORCH_MD="${CEKERNEL_DIR}/agents/orchestrator.md"

# ── Test 1: spawn.sh sources resolve-repo-root.sh ──
if file_contains 'resolve-repo-root.sh' "$SPAWN_SH"; then
  echo "  PASS: spawn.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: spawn.sh uses resolve_repo_root (not raw git rev-parse) ──
if file_contains 'resolve_repo_root' "$SPAWN_SH"; then
  echo "  PASS: spawn.sh uses resolve_repo_root"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should use resolve_repo_root"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: spawn.sh does NOT use raw git rev-parse --show-toplevel for REPO_ROOT ──
if file_contains 'REPO_ROOT=.*git rev-parse --show-toplevel' "$SPAWN_SH"; then
  echo "  FAIL: spawn.sh should not use raw git rev-parse --show-toplevel for REPO_ROOT"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: spawn.sh does not use raw git rev-parse for REPO_ROOT"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 4: cleanup-worktree.sh sources resolve-repo-root.sh ──
if file_contains 'resolve-repo-root.sh' "$CLEANUP_SH"; then
  echo "  PASS: cleanup-worktree.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: cleanup-worktree.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: cleanup-worktree.sh uses resolve_repo_root ──
if file_contains 'resolve_repo_root' "$CLEANUP_SH"; then
  echo "  PASS: cleanup-worktree.sh uses resolve_repo_root"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: cleanup-worktree.sh should use resolve_repo_root"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: spawn-orchestrator.sh sources resolve-repo-root.sh ──
if file_contains 'resolve-repo-root.sh' "$SPAWN_ORCH_SH"; then
  echo "  PASS: spawn-orchestrator.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-orchestrator.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: process-status.sh sources resolve-repo-root.sh ──
if file_contains 'resolve-repo-root.sh' "$PROCESS_STATUS_SH"; then
  echo "  PASS: process-status.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: process-status.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: notify-complete.sh sources resolve-repo-root.sh ──
if file_contains 'resolve-repo-root.sh' "$NOTIFY_COMPLETE_SH"; then
  echo "  PASS: notify-complete.sh sources resolve-repo-root.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: notify-complete.sh should source resolve-repo-root.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: orchestrator.md documents CWD convention ──
if file_contains 'CWD Convention' "$ORCH_MD"; then
  echo "  PASS: orchestrator.md documents CWD Convention"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: orchestrator.md should document CWD Convention"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: orchestrator.md recommends git -C ──
if file_contains 'git -C' "$ORCH_MD"; then
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
