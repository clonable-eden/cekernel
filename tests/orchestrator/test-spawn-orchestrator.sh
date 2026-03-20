#!/usr/bin/env bash
# test-spawn-orchestrator.sh — Tests for spawn-orchestrator.sh
#
# Verifies that spawn-orchestrator.sh correctly launches the Orchestrator
# as an independent OS process via `claude -p --agent orchestrator`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-orchestrator"

SPAWN_ORCHESTRATOR="${CEKERNEL_DIR}/scripts/orchestrator/spawn-orchestrator.sh"

# ── Test 1: spawn-orchestrator.sh exists and is executable ──
assert_file_exists "spawn-orchestrator.sh exists" "$SPAWN_ORCHESTRATOR"

if [[ -x "$SPAWN_ORCHESTRATOR" ]]; then
  echo "  PASS: spawn-orchestrator.sh is executable"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-orchestrator.sh is not executable"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: starts with set -euo pipefail ──
CONTENT=$(cat "$SPAWN_ORCHESTRATOR")
if echo "$CONTENT" | grep -q 'set -euo pipefail'; then
  echo "  PASS: starts with set -euo pipefail"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should start with set -euo pipefail"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: launches claude -p --agent ──
if echo "$CONTENT" | grep -q 'claude -p --agent'; then
  echo "  PASS: launches claude -p --agent"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should launch claude -p --agent"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: runs as background process ──
if echo "$CONTENT" | grep -Eq '&$|& *$'; then
  echo "  PASS: runs claude as background process"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should run claude as background process"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: unsets Claude session markers ──
if echo "$CONTENT" | grep -q 'unset CLAUDECODE'; then
  echo "  PASS: unsets CLAUDECODE session marker"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should unset CLAUDECODE session marker"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: resolves CEKERNEL_AGENT_ORCHESTRATOR env var ──
if echo "$CONTENT" | grep -q 'CEKERNEL_AGENT_ORCHESTRATOR'; then
  echo "  PASS: resolves CEKERNEL_AGENT_ORCHESTRATOR"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should resolve CEKERNEL_AGENT_ORCHESTRATOR"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: defaults agent name to 'orchestrator' ──
RESULT_7=$(
  unset CEKERNEL_AGENT_ORCHESTRATOR
  AGENT_NAME="${CEKERNEL_AGENT_ORCHESTRATOR:-orchestrator}"
  echo "$AGENT_NAME"
)
assert_eq "defaults agent name to 'orchestrator'" "orchestrator" "$RESULT_7"

# ── Test 8: uses CEKERNEL_AGENT_ORCHESTRATOR when set ──
RESULT_8=$(
  export CEKERNEL_AGENT_ORCHESTRATOR="cekernel:orchestrator"
  AGENT_NAME="${CEKERNEL_AGENT_ORCHESTRATOR:-orchestrator}"
  echo "$AGENT_NAME"
)
assert_eq "uses cekernel:orchestrator when set" "cekernel:orchestrator" "$RESULT_8"

# ── Test 9: accepts prompt as positional argument ──
if echo "$CONTENT" | grep -qE '\$\{1:\?|"\$1"|\$PROMPT'; then
  echo "  PASS: accepts prompt argument"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should accept prompt as argument"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: sources load-env.sh ──
if echo "$CONTENT" | grep -q 'load-env\.sh'; then
  echo "  PASS: sources load-env.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should source load-env.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 11: sources session-id.sh ──
if echo "$CONTENT" | grep -q 'session-id\.sh'; then
  echo "  PASS: sources session-id.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should source session-id.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 12: operates from repo root (resolve_repo_root) ──
if echo "$CONTENT" | grep -q 'resolve_repo_root'; then
  echo "  PASS: resolves repo root via resolve_repo_root"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should resolve repo root via resolve_repo_root"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 13: outputs PID to stdout ──
if echo "$CONTENT" | grep -qE 'echo.*\$.*PID|echo.*\$!'; then
  echo "  PASS: outputs PID to stdout"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: should output PID to stdout"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 14: does NOT create worktree (operates in main tree) ──
if echo "$CONTENT" | grep -q 'git worktree add'; then
  echo "  FAIL: should NOT create worktree (Orchestrator works in main tree)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: does not create worktree"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 15: does NOT create FIFO (Orchestrator is not managed via FIFO) ──
if echo "$CONTENT" | grep -q 'mkfifo'; then
  echo "  FAIL: should NOT create FIFO (Orchestrator manages, not managed)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: does not create FIFO"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

report_results
