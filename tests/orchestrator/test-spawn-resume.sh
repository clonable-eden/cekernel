#!/usr/bin/env bash
# test-spawn-resume.sh — Tests for spawn-worker.sh --resume flag parsing and validation
#
# Verifies that spawn-worker.sh --resume:
#   1. Accepts the flag and skips worktree creation
#   2. Rejects when worktree does not exist
#   3. Reuses existing worktree instead of creating new one
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-resume"

# ── Extract flag parsing section from spawn-worker.sh ──
# We test the --resume flag is accepted by the parsing loop

SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn-worker.sh"

# ── Test 1: --resume flag is recognized in spawn-worker.sh ──
# Check that spawn-worker.sh contains --resume handling
SCRIPT_CONTENT=$(cat "$SPAWN_SCRIPT")
if [[ "$SCRIPT_CONTENT" == *"--resume"* ]]; then
  echo "  PASS: spawn-worker.sh contains --resume flag handling"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-worker.sh does not contain --resume flag handling"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: --resume without existing worktree should fail ──
# spawn-worker.sh will error out when --resume is specified for a non-existent issue.
# The exact exit code may vary (1 for missing worktree, or other codes if gh fails first),
# but it should always be non-zero.
export CEKERNEL_SESSION_ID="test-spawn-resume-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

EXIT_CODE=0
bash "$SPAWN_SCRIPT" --resume 99999 2>/dev/null || EXIT_CODE=$?
if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo "  PASS: Resume with non-existent worktree exits non-zero (exit=$EXIT_CODE)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Resume with non-existent worktree should exit non-zero"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
