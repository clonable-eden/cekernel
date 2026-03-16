#!/usr/bin/env bash
# test-spawn-env-propagation.sh — Tests that spawn.sh writes .cekernel-env
# and that PATH is propagated via runner script (not via LLM PROMPT prefix).
#
# Verifies:
# 1. .cekernel-env is written to the worktree with all env vars
# 2. BASH_PREFIX removed: spawn.sh does not embed prefix instruction in PROMPT
# 3. PROMPT strings do not include "When executing Bash" prefix instruction
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

# ── Test 3: BASH_PREFIX removed — spawn.sh must not define BASH_PREFIX ──
# PATH is now propagated via .cekernel-env sourced by the runner script.
if [[ "$SCRIPT_CONTENT" != *'BASH_PREFIX='* ]]; then
  echo "  PASS: BASH_PREFIX removed from spawn.sh (PATH via runner script)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: BASH_PREFIX still present in spawn.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: PROMPT strings do NOT contain the "When executing Bash" prefix instruction ──
if [[ "$SCRIPT_CONTENT" != *'When executing Bash'* ]]; then
  echo "  PASS: PROMPT does not contain 'When executing Bash' prefix instruction"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: PROMPT still contains 'When executing Bash' prefix instruction"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: runner.sh sources .cekernel-env in generated script ──
RUNNER_SCRIPT="${CEKERNEL_DIR}/scripts/shared/runner.sh"
if grep -q 'source .cekernel-env' "$RUNNER_SCRIPT"; then
  echo "  PASS: runner.sh generates scripts that source .cekernel-env"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: runner.sh does not source .cekernel-env"
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

# ── Test 9: .cekernel-env is referenced in spawn.sh (write + comments) ──
# The env file write is the key reference; comments confirm intent.
ENV_WRITE_COUNT=$(grep -c 'cekernel-env' "$SPAWN_SCRIPT" || true)
if [[ "$ENV_WRITE_COUNT" -ge 3 ]]; then
  echo "  PASS: .cekernel-env referenced multiple times in spawn.sh (count=$ENV_WRITE_COUNT)"
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
