#!/usr/bin/env bash
# test-spawn-env-propagation.sh — Tests that spawn-worker.sh propagates CEKERNEL_ENV to Worker prompts
#
# Verifies that both normal and resume PROMPT strings include
# export CEKERNEL_ENV=${CEKERNEL_ENV}, as required by ADR-0010.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn-worker.sh"

echo "test: spawn-env-propagation"

SCRIPT_CONTENT=$(cat "$SPAWN_SCRIPT")

# ── Test 1: Normal PROMPT includes CEKERNEL_ENV export ──
# The normal (non-resume) PROMPT should contain export CEKERNEL_ENV=
if [[ "$SCRIPT_CONTENT" == *'export CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID}'*'export CEKERNEL_ENV=${CEKERNEL_ENV}'* ]]; then
  echo "  PASS: Normal PROMPT includes CEKERNEL_ENV export"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Normal PROMPT missing CEKERNEL_ENV export"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: Resume PROMPT includes CEKERNEL_ENV export ──
# The resume PROMPT should also contain export CEKERNEL_ENV=
# Both PROMPT strings should have it
PROMPT_COUNT=$(grep -c 'export CEKERNEL_ENV=\${CEKERNEL_ENV}' "$SPAWN_SCRIPT" || true)
if [[ "$PROMPT_COUNT" -ge 2 ]]; then
  echo "  PASS: Both PROMPT strings include CEKERNEL_ENV export (count=$PROMPT_COUNT)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Expected CEKERNEL_ENV in both PROMPT strings, found $PROMPT_COUNT"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

report_results
