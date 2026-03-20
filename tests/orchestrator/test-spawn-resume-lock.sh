#!/usr/bin/env bash
# test-spawn-resume-lock.sh — Tests that spawn.sh skips issue_lock_acquire on --resume
#
# When spawn-reviewer.sh (or any --resume spawn) is called, the issue lock
# is already held by the previous process (Worker). Re-acquiring the lock
# would fail with exit 2. spawn.sh must skip issue_lock_acquire when RESUME=1,
# relying on issue_lock_update_pid to transfer ownership.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-resume-lock"

SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
SPAWN_CONTENT=$(cat "$SPAWN_SCRIPT")

# ── Test 1: spawn.sh conditionally skips issue_lock_acquire on --resume ──
# The lock acquisition block must be guarded by RESUME check.
# Expected pattern: only acquire lock when RESUME=0 (fresh spawn).
if echo "$SPAWN_CONTENT" | grep -qE 'RESUME.*-eq 0.*issue_lock_acquire|if.*RESUME.*0.*then.*issue_lock_acquire'; then
  echo "  PASS: spawn.sh skips issue_lock_acquire when RESUME=1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  # Also check for an if-block wrapping the lock acquire
  # e.g., if [[ "$RESUME" -eq 0 ]]; then ... issue_lock_acquire ... fi
  LOCK_SECTION=$(echo "$SPAWN_CONTENT" | grep -B5 'issue_lock_acquire' | head -10)
  if echo "$LOCK_SECTION" | grep -q 'RESUME'; then
    echo "  PASS: spawn.sh skips issue_lock_acquire when RESUME=1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "  FAIL: spawn.sh should skip issue_lock_acquire when RESUME=1"
    echo "    Lock acquire section does not check RESUME flag."
    echo "    Context: $(echo "$LOCK_SECTION" | tr '\n' ' ')"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
fi

# ── Test 2: spawn.sh still acquires lock for fresh spawn (RESUME=0) ──
# Ensure issue_lock_acquire is still present (not entirely removed)
if echo "$SPAWN_CONTENT" | grep -q 'issue_lock_acquire'; then
  echo "  PASS: spawn.sh still calls issue_lock_acquire for fresh spawns"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should still call issue_lock_acquire for fresh spawns"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: spawn.sh rollback only releases lock for fresh spawn ──
# In resume mode, the lock should NOT be released on rollback (the lock
# belongs to the lifecycle, not to this spawn attempt).
# Extract the lock release section from rollback and check it is guarded.
ROLLBACK_SECTION=$(echo "$SPAWN_CONTENT" | sed -n '/^rollback()/,/^}/p')
LOCK_RELEASE_CONTEXT=$(echo "$ROLLBACK_SECTION" | grep -B3 'issue_lock_release')
if echo "$LOCK_RELEASE_CONTEXT" | grep -q 'RESUME'; then
  echo "  PASS: spawn.sh rollback guards lock release with RESUME check"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh rollback should guard lock release with RESUME check"
  echo "    Releasing the lock on rollback in resume mode would break the lifecycle."
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

report_results
