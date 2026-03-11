#!/usr/bin/env bash
# test-spawn-env-propagation.sh — Tests that spawn.sh writes .cekernel-env
# and uses a short BASH_PREFIX ("source .cekernel-env")
#
# Verifies:
# 1. .cekernel-env is written to the worktree with all env vars
# 2. BASH_PREFIX is "source .cekernel-env" (not the full export string)
# 3. Both PROMPT strings use the short BASH_PREFIX
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"

echo "test: spawn-env-propagation"

SCRIPT_CONTENT=$(cat "$SPAWN_SCRIPT")

# ── Test 1: spawn.sh writes .cekernel-env to worktree ──
# The script must contain a heredoc or cat that creates .cekernel-env
if [[ "$SCRIPT_CONTENT" == *'.cekernel-env'* ]]; then
  echo "  PASS: spawn.sh references .cekernel-env"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not reference .cekernel-env"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: .cekernel-env includes CEKERNEL_SESSION_ID ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_SESSION_ID='*'.cekernel-env'* ]] || \
   grep -q 'CEKERNEL_SESSION_ID=.*cekernel-env\|cekernel-env.*CEKERNEL_SESSION_ID' "$SPAWN_SCRIPT"; then
  echo "  PASS: .cekernel-env includes CEKERNEL_SESSION_ID"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: .cekernel-env missing CEKERNEL_SESSION_ID"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: BASH_PREFIX uses "source .cekernel-env" (short form) ──
if [[ "$SCRIPT_CONTENT" == *'BASH_PREFIX="source .cekernel-env"'* ]]; then
  echo "  PASS: BASH_PREFIX is short form (source .cekernel-env)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: BASH_PREFIX is not 'source .cekernel-env'"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: BASH_PREFIX does NOT contain the long export string ──
if [[ "$SCRIPT_CONTENT" != *'BASH_PREFIX="export CEKERNEL_SESSION_ID='* ]]; then
  echo "  PASS: BASH_PREFIX does not contain long export string"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: BASH_PREFIX still contains long export string"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: Both PROMPT strings use BASH_PREFIX ──
PROMPT_COUNT=$(grep -c '${BASH_PREFIX}' "$SPAWN_SCRIPT" || true)
if [[ "$PROMPT_COUNT" -ge 2 ]]; then
  echo "  PASS: Both PROMPT strings use BASH_PREFIX (count=$PROMPT_COUNT)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Expected BASH_PREFIX in both PROMPT strings, found $PROMPT_COUNT"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: Worker script directories are computed from SCRIPT_DIR ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_WORKER_SCRIPTS="$(cd "${SCRIPT_DIR}/../process" && pwd)"'* ]]; then
  echo "  PASS: CEKERNEL_WORKER_SCRIPTS computed from SCRIPT_DIR"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: CEKERNEL_WORKER_SCRIPTS not computed from SCRIPT_DIR"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: Shared script directories are computed from SCRIPT_DIR ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_SHARED_SCRIPTS="$(cd "${SCRIPT_DIR}/../shared" && pwd)"'* ]]; then
  echo "  PASS: CEKERNEL_SHARED_SCRIPTS computed from SCRIPT_DIR"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: CEKERNEL_SHARED_SCRIPTS not computed from SCRIPT_DIR"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: Script directories actually exist ──
WORKER_SCRIPTS_DIR="${CEKERNEL_DIR}/scripts/process"
SHARED_SCRIPTS_DIR="${CEKERNEL_DIR}/scripts/shared"
assert_dir_exists "scripts/process directory exists" "$WORKER_SCRIPTS_DIR"
assert_dir_exists "scripts/shared directory exists" "$SHARED_SCRIPTS_DIR"

# ── Test 9: .cekernel-env is written for both normal and resume modes ──
# The env file must be generated in both code paths (not just normal mode)
ENV_WRITE_COUNT=$(grep -c 'cekernel-env' "$SPAWN_SCRIPT" || true)
if [[ "$ENV_WRITE_COUNT" -ge 3 ]]; then
  echo "  PASS: .cekernel-env referenced multiple times (write + BASH_PREFIX + PROMPT or more)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Expected .cekernel-env to be referenced at least 3 times, found $ENV_WRITE_COUNT"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: .cekernel-env includes PATH with $PATH preservation ──
# The env file must append to existing PATH (:\$PATH) to avoid losing /usr/bin etc.
# Check spawn.sh (which now contains the logic)
if grep -q 'PATH=.*:\$PATH' "$SPAWN_SCRIPT" || grep -q 'PATH=.*:\\$PATH' "$SPAWN_SCRIPT"; then
  echo "  PASS: .cekernel-env preserves existing PATH (:\$PATH)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: .cekernel-env does not preserve existing PATH"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

report_results
