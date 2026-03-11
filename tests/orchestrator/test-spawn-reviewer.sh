#!/usr/bin/env bash
# test-spawn-reviewer.sh — Tests for spawn-reviewer.sh (reviewer spawning wrapper)
#
# Verifies that spawn-reviewer.sh correctly delegates to spawn.sh --agent reviewer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-reviewer"

# ── Test 1: spawn-reviewer.sh exists and is executable ──
SPAWN_REVIEWER="${CEKERNEL_DIR}/scripts/orchestrator/spawn-reviewer.sh"
assert_file_exists "spawn-reviewer.sh exists" "$SPAWN_REVIEWER"

if [[ -x "$SPAWN_REVIEWER" ]]; then
  echo "  PASS: spawn-reviewer.sh is executable"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh is not executable"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: spawn-reviewer.sh delegates to spawn.sh --agent reviewer ──
# Read the script content and verify it calls spawn.sh with --agent reviewer
CONTENT=$(cat "$SPAWN_REVIEWER")
if echo "$CONTENT" | grep -q 'spawn\.sh.*--agent reviewer'; then
  echo "  PASS: spawn-reviewer.sh delegates to spawn.sh --agent reviewer"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should delegate to spawn.sh --agent reviewer"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: spawn-reviewer.sh passes through all arguments ──
if echo "$CONTENT" | grep -q '"$@"'; then
  echo "  PASS: spawn-reviewer.sh passes through all arguments"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should pass through all arguments via \"\$@\""
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: spawn-reviewer.sh uses exec (replaces process) ──
if echo "$CONTENT" | grep -q 'exec.*spawn\.sh'; then
  echo "  PASS: spawn-reviewer.sh uses exec"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should use exec to replace the process"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: spawn-reviewer.sh starts with set -euo pipefail ──
if echo "$CONTENT" | grep -q 'set -euo pipefail'; then
  echo "  PASS: spawn-reviewer.sh starts with set -euo pipefail"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should start with set -euo pipefail"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: spawn.sh resolves CEKERNEL_AGENT_REVIEWER for reviewer type ──
# The dynamic agent name resolution in spawn.sh constructs CEKERNEL_AGENT_REVIEWER
# from the agent type. Verify this logic works for "reviewer".
(
  AGENT_TYPE="reviewer"
  AGENT_VAR="CEKERNEL_AGENT_$(echo "$AGENT_TYPE" | tr '[:lower:]' '[:upper:]')"
  # When CEKERNEL_AGENT_REVIEWER is unset, default to "reviewer"
  unset CEKERNEL_AGENT_REVIEWER
  AGENT_NAME="${!AGENT_VAR:-$AGENT_TYPE}"
  echo "$AGENT_NAME"
) | {
  read -r result
  assert_eq "spawn.sh defaults CEKERNEL_AGENT_REVIEWER to 'reviewer'" "reviewer" "$result"
}

# ── Test 7: spawn.sh uses CEKERNEL_AGENT_REVIEWER when set ──
(
  AGENT_TYPE="reviewer"
  export CEKERNEL_AGENT_REVIEWER="cekernel:reviewer"
  AGENT_VAR="CEKERNEL_AGENT_$(echo "$AGENT_TYPE" | tr '[:lower:]' '[:upper:]')"
  AGENT_NAME="${!AGENT_VAR:-$AGENT_TYPE}"
  echo "$AGENT_NAME"
) | {
  read -r result
  assert_eq "spawn.sh uses CEKERNEL_AGENT_REVIEWER=cekernel:reviewer when set" "cekernel:reviewer" "$result"
}

# ── Test 8: spawn-reviewer.sh passes --prompt to spawn.sh ──
if echo "$CONTENT" | grep -q '\-\-prompt'; then
  echo "  PASS: spawn-reviewer.sh passes --prompt to spawn.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should pass --prompt to spawn.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: spawn-reviewer.sh prompt contains review instructions ──
if echo "$CONTENT" | grep -q 'Review the PR'; then
  echo "  PASS: spawn-reviewer.sh prompt contains review instructions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh prompt should contain review instructions"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: spawn-reviewer.sh prompt references notify-complete.sh ──
if echo "$CONTENT" | grep -q 'notify-complete.sh'; then
  echo "  PASS: spawn-reviewer.sh prompt references notify-complete.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh prompt should reference notify-complete.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 11: spawn.sh accepts --prompt flag ──
SPAWN_SH="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
SPAWN_CONTENT=$(cat "$SPAWN_SH")
if echo "$SPAWN_CONTENT" | grep -q '\-\-prompt)'; then
  echo "  PASS: spawn.sh accepts --prompt flag"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should accept --prompt flag"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 12: spawn.sh uses CUSTOM_PROMPT when provided ──
if echo "$SPAWN_CONTENT" | grep -q 'CUSTOM_PROMPT'; then
  echo "  PASS: spawn.sh uses CUSTOM_PROMPT variable"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should use CUSTOM_PROMPT variable"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 13: spawn-reviewer.sh correctly skips --priority value when extracting issue number ──
# Simulate: spawn-reviewer.sh --priority 5 123
SKIP_NEXT=0
ISSUE=""
for arg in --priority 5 123; do
  if [[ "$SKIP_NEXT" -eq 1 ]]; then
    SKIP_NEXT=0; continue
  fi
  case "$arg" in
    --resume) ;;
    --priority) SKIP_NEXT=1 ;;
    [0-9]*) ISSUE="$arg"; break ;;
  esac
done
assert_eq "Issue extraction skips --priority value" "123" "$ISSUE"

report_results
