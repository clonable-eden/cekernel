#!/usr/bin/env bash
# test-spawn-reviewer.sh — Tests for spawn-reviewer.sh (reviewer spawning wrapper)
#
# Verifies that spawn-reviewer.sh correctly delegates to spawn.sh --agent reviewer
# with the <issue-number> <pr-number> interface.
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
CONTENT=$(cat "$SPAWN_REVIEWER")
if echo "$CONTENT" | grep -q 'spawn\.sh.*--agent reviewer'; then
  echo "  PASS: spawn-reviewer.sh delegates to spawn.sh --agent reviewer"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should delegate to spawn.sh --agent reviewer"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: spawn-reviewer.sh uses exec (replaces process) ──
if echo "$CONTENT" | grep -q 'exec.*spawn\.sh'; then
  echo "  PASS: spawn-reviewer.sh uses exec"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should use exec to replace the process"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: spawn-reviewer.sh starts with set -euo pipefail ──
if echo "$CONTENT" | grep -q 'set -euo pipefail'; then
  echo "  PASS: spawn-reviewer.sh starts with set -euo pipefail"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should start with set -euo pipefail"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: spawn.sh resolves CEKERNEL_AGENT_REVIEWER for reviewer type ──
RESULT_5=$(
  AGENT_TYPE="reviewer"
  AGENT_VAR="CEKERNEL_AGENT_$(echo "$AGENT_TYPE" | tr '[:lower:]' '[:upper:]')"
  unset CEKERNEL_AGENT_REVIEWER
  AGENT_NAME="${!AGENT_VAR:-$AGENT_TYPE}"
  echo "$AGENT_NAME"
)
assert_eq "spawn.sh defaults CEKERNEL_AGENT_REVIEWER to 'reviewer'" "reviewer" "$RESULT_5"

# ── Test 6: spawn.sh uses CEKERNEL_AGENT_REVIEWER when set ──
RESULT_6=$(
  AGENT_TYPE="reviewer"
  export CEKERNEL_AGENT_REVIEWER="cekernel:reviewer"
  AGENT_VAR="CEKERNEL_AGENT_$(echo "$AGENT_TYPE" | tr '[:lower:]' '[:upper:]')"
  AGENT_NAME="${!AGENT_VAR:-$AGENT_TYPE}"
  echo "$AGENT_NAME"
)
assert_eq "spawn.sh uses CEKERNEL_AGENT_REVIEWER=cekernel:reviewer when set" "cekernel:reviewer" "$RESULT_6"

# ── Test 7: spawn-reviewer.sh passes --prompt to spawn.sh ──
if echo "$CONTENT" | grep -q '\-\-prompt'; then
  echo "  PASS: spawn-reviewer.sh passes --prompt to spawn.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should pass --prompt to spawn.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: spawn-reviewer.sh prompt contains review instructions ──
if echo "$CONTENT" | grep -q 'Review the PR'; then
  echo "  PASS: spawn-reviewer.sh prompt contains review instructions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh prompt should contain review instructions"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: spawn-reviewer.sh prompt references notify-complete.sh ──
if echo "$CONTENT" | grep -q 'notify-complete.sh'; then
  echo "  PASS: spawn-reviewer.sh prompt references notify-complete.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh prompt should reference notify-complete.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: spawn.sh accepts --prompt flag ──
SPAWN_SH="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
SPAWN_CONTENT=$(cat "$SPAWN_SH")
if echo "$SPAWN_CONTENT" | grep -q '\-\-prompt)'; then
  echo "  PASS: spawn.sh accepts --prompt flag"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should accept --prompt flag"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 11: spawn.sh uses CUSTOM_PROMPT when provided ──
if echo "$SPAWN_CONTENT" | grep -q 'CUSTOM_PROMPT'; then
  echo "  PASS: spawn.sh uses CUSTOM_PROMPT variable"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should use CUSTOM_PROMPT variable"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 12: spawn-reviewer.sh requires <issue-number> <pr-number> (two positional args) ──
# Usage header should document <issue-number> <pr-number>
if echo "$CONTENT" | grep -q '<issue-number> <pr-number>'; then
  echo "  PASS: spawn-reviewer.sh documents <issue-number> <pr-number> interface"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should document <issue-number> <pr-number> interface"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 13: spawn-reviewer.sh validates PR_NUMBER is required ──
# The script should use ${2:?...} or equivalent for PR_NUMBER
if echo "$CONTENT" | grep -qE 'PR_NUMBER.*\$\{2:\?' || echo "$CONTENT" | grep -qE 'PR_NUMBER="\$\{'; then
  echo "  PASS: spawn-reviewer.sh validates PR_NUMBER as required"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should validate PR_NUMBER as required"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 14: spawn-reviewer.sh passes issue number (not PR number) to spawn.sh ──
# The exec line should pass ISSUE_NUMBER to spawn.sh, not PR_NUMBER.
# State management must use issue number for consistency with Workers.
if echo "$CONTENT" | grep -q 'exec.*spawn\.sh.*"\$ISSUE_NUMBER"'; then
  echo "  PASS: spawn-reviewer.sh passes issue number to spawn.sh"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh should pass issue number (not PR number) to spawn.sh"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 15: spawn-reviewer.sh prompt includes PR_NUMBER variable ──
# The reviewer prompt should reference the PR number so the reviewer knows which PR to review
if echo "$CONTENT" | grep -q '\$.*PR_NUMBER'; then
  echo "  PASS: spawn-reviewer.sh prompt includes PR_NUMBER"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh prompt should include PR_NUMBER for the reviewer"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 16: spawn-reviewer.sh prompt embeds PR number in gh pr review instruction ──
if echo "$CONTENT" | grep -q 'gh pr review'; then
  echo "  PASS: spawn-reviewer.sh prompt includes gh pr review instruction"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn-reviewer.sh prompt should include gh pr review instruction"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 17: spawn-reviewer.sh extracts flags correctly with new interface ──
# Simulate arg parsing: spawn-reviewer.sh --priority high 267 296
# Should extract ISSUE=267, PR=296
SKIP_NEXT=0
ARGS_POSITIONAL=()
for arg in --priority high 267 296; do
  if [[ "$SKIP_NEXT" -eq 1 ]]; then
    SKIP_NEXT=0; continue
  fi
  case "$arg" in
    --priority) SKIP_NEXT=1 ;;
    *) ARGS_POSITIONAL+=("$arg") ;;
  esac
done
assert_eq "Positional arg extraction: issue" "267" "${ARGS_POSITIONAL[0]}"
assert_eq "Positional arg extraction: pr" "296" "${ARGS_POSITIONAL[1]}"

report_results
