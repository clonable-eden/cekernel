#!/usr/bin/env bash
# test-spawn-checkpoint-warning.sh — Tests for checkpoint warning suppression in spawn.sh
#
# Verifies that spawn.sh only shows the checkpoint warning when resuming Workers,
# not when resuming Reviewers (checkpoints are a Worker-only concept, written on SUSPEND).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-checkpoint-warning"

SPAWN_SH="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
SPAWN_CONTENT=$(cat "$SPAWN_SH")

# ── Test 1: spawn.sh checkpoint warning is conditional on agent type ──
# The checkpoint existence check in resume mode should only warn for Workers.
# Reviewer resumes should NOT produce a "Warning: no checkpoint file found" message
# because checkpoints are a Worker-only concept (written on SUSPEND signal).
if echo "$SPAWN_CONTENT" | grep -q 'AGENT_TYPE.*worker.*checkpoint\|checkpoint.*AGENT_TYPE.*worker'; then
  echo "  PASS: Checkpoint warning is conditional on AGENT_TYPE"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Checkpoint warning should be conditional on AGENT_TYPE (worker only)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: spawn.sh does not unconditionally warn about missing checkpoint ──
# The old pattern was: if checkpoint_file_exists; then ... else Warning ...
# The new pattern should gate the entire checkpoint check behind an agent type check.
# Count occurrences of the checkpoint warning to ensure it's inside a conditional.
WARNING_LINES=$(echo "$SPAWN_CONTENT" | grep -c 'Warning.*no checkpoint file found' || true)
CONDITIONAL_LINES=$(echo "$SPAWN_CONTENT" | grep -c 'AGENT_TYPE.*worker' || true)
if [[ "$WARNING_LINES" -gt 0 && "$CONDITIONAL_LINES" -gt 0 ]]; then
  echo "  PASS: Warning exists with agent type guard"
  TESTS_PASSED=$((TESTS_PASSED + 1))
elif [[ "$WARNING_LINES" -eq 0 ]]; then
  # Warning removed entirely — also acceptable (Reviewer never sees it)
  echo "  PASS: Checkpoint warning removed (acceptable)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Checkpoint warning exists without agent type guard"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

report_results
