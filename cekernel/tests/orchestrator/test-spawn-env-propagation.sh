#!/usr/bin/env bash
# test-spawn-env-propagation.sh — Tests that spawn-worker.sh propagates env to Worker prompts
#
# Verifies that the BASH_PREFIX includes CEKERNEL_SESSION_ID, CEKERNEL_IPC_DIR,
# CEKERNEL_ENV, and PATH with cekernel script directories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn-worker.sh"

echo "test: spawn-env-propagation"

SCRIPT_CONTENT=$(cat "$SPAWN_SCRIPT")

# ── Test 1: BASH_PREFIX includes CEKERNEL_SESSION_ID ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID}'* ]]; then
  echo "  PASS: BASH_PREFIX includes CEKERNEL_SESSION_ID"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: BASH_PREFIX missing CEKERNEL_SESSION_ID"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: BASH_PREFIX includes CEKERNEL_IPC_DIR ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_IPC_DIR=${CEKERNEL_IPC_DIR}'* ]]; then
  echo "  PASS: BASH_PREFIX includes CEKERNEL_IPC_DIR"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: BASH_PREFIX missing CEKERNEL_IPC_DIR"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: BASH_PREFIX includes CEKERNEL_ENV ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_ENV=${CEKERNEL_ENV}'* ]]; then
  echo "  PASS: BASH_PREFIX includes CEKERNEL_ENV"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: BASH_PREFIX missing CEKERNEL_ENV"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: BASH_PREFIX includes PATH with worker scripts ──
if [[ "$SCRIPT_CONTENT" == *'PATH=${CEKERNEL_WORKER_SCRIPTS}:${CEKERNEL_SHARED_SCRIPTS}:'* ]]; then
  echo "  PASS: BASH_PREFIX includes PATH with worker/shared scripts"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: BASH_PREFIX missing PATH with script directories"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: Worker script directories are computed from SCRIPT_DIR ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_WORKER_SCRIPTS="$(cd "${SCRIPT_DIR}/../worker" && pwd)"'* ]]; then
  echo "  PASS: CEKERNEL_WORKER_SCRIPTS computed from SCRIPT_DIR"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: CEKERNEL_WORKER_SCRIPTS not computed from SCRIPT_DIR"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: Shared script directories are computed from SCRIPT_DIR ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_SHARED_SCRIPTS="$(cd "${SCRIPT_DIR}/../shared" && pwd)"'* ]]; then
  echo "  PASS: CEKERNEL_SHARED_SCRIPTS computed from SCRIPT_DIR"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: CEKERNEL_SHARED_SCRIPTS not computed from SCRIPT_DIR"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: Both PROMPT strings use BASH_PREFIX ──
PROMPT_COUNT=$(grep -c '${BASH_PREFIX}' "$SPAWN_SCRIPT" || true)
if [[ "$PROMPT_COUNT" -ge 2 ]]; then
  echo "  PASS: Both PROMPT strings use BASH_PREFIX (count=$PROMPT_COUNT)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Expected BASH_PREFIX in both PROMPT strings, found $PROMPT_COUNT"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: Script directories actually exist ──
WORKER_SCRIPTS_DIR="${CEKERNEL_DIR}/scripts/worker"
SHARED_SCRIPTS_DIR="${CEKERNEL_DIR}/scripts/shared"
assert_dir_exists "scripts/worker directory exists" "$WORKER_SCRIPTS_DIR"
assert_dir_exists "scripts/shared directory exists" "$SHARED_SCRIPTS_DIR"

report_results
