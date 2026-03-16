#!/usr/bin/env bash
# test-runner.sh — Tests for runner.sh helper
#
# Tests the write_runner_script function that generates runner scripts
# for Worker processes, with prompt passed via file (no escaping needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: runner"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-runner-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Source runner.sh ──
source "${CEKERNEL_DIR}/scripts/shared/runner.sh"

# ── Test 1: write_runner_script creates runner file ──
RUNNER=$(write_runner_script "42" "/tmp/worktree" "test-session" "worker" "hello world")
assert_file_exists "write_runner_script creates runner file" "$RUNNER"

# ── Test 2: Runner file is executable ──
if [[ -x "$RUNNER" ]]; then
  echo "  PASS: runner file is executable"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: runner file is not executable"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: Prompt file is created ──
assert_file_exists "prompt file created" "${CEKERNEL_IPC_DIR}/prompt-42.txt"

# ── Test 4: Prompt file contains exact prompt text ──
PROMPT_CONTENT=$(cat "${CEKERNEL_IPC_DIR}/prompt-42.txt")
assert_eq "prompt file content" "hello world" "$PROMPT_CONTENT"

# ── Test 5: Runner script contains cd to worktree ──
assert_match "runner contains cd" "cd '/tmp/worktree'" "$(cat "$RUNNER")"

# ── Test 6: Runner script does not explicitly export session ID (handled by .cekernel-env) ──
if ! grep -q "export CEKERNEL_SESSION_ID" "$RUNNER"; then
  echo "  PASS: runner does not explicitly export SESSION_ID (delegated to .cekernel-env)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: runner still explicitly exports SESSION_ID"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: Runner script contains agent name ──
assert_match "runner contains agent name" "agent worker" "$(cat "$RUNNER")"

# ── Test 8: Runner script reads prompt from file (not embedded) ──
RUNNER_CONTENT=$(cat "$RUNNER")
assert_match "runner reads prompt from file" 'cat.*prompt-42.txt' "$RUNNER_CONTENT"
# Prompt value should NOT appear in runner script
if echo "$RUNNER_CONTENT" | grep -qF "hello world"; then
  echo "  FAIL: prompt value is embedded in runner (should be file-based)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: prompt value is not embedded in runner"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 9: Runner script unsets Claude Code env vars ──
assert_match "runner unsets CLAUDECODE" "unset CLAUDECODE" "$RUNNER_CONTENT"

# ── Test 10: Runner script does not use script command ──
if echo "$RUNNER_CONTENT" | grep -q "exec script "; then
  echo "  FAIL: runner still uses script command"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: runner does not use script command"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 11: Runner script uses exec claude directly ──
assert_match "runner uses exec claude" "exec claude -p --agent" "$RUNNER_CONTENT"

# ── Test 12: Runner script sources .cekernel-env ──
assert_match "runner sources .cekernel-env" "source .cekernel-env" "$RUNNER_CONTENT"

# ── Test 13: Prompt with double quotes ──
write_runner_script "43" "/tmp/wt" "s" "worker" 'Resolve "issue"' >/dev/null
PROMPT_43=$(cat "${CEKERNEL_IPC_DIR}/prompt-43.txt")
assert_eq "double quotes preserved" 'Resolve "issue"' "$PROMPT_43"

# ── Test 14: Prompt with single quotes ──
write_runner_script "44" "/tmp/wt" "s" "worker" "It's a test" >/dev/null
PROMPT_44=$(cat "${CEKERNEL_IPC_DIR}/prompt-44.txt")
assert_eq "single quotes preserved" "It's a test" "$PROMPT_44"

# ── Test 15: Prompt with shell metacharacters ──
write_runner_script "45" "/tmp/wt" "s" "worker" 'Value is $(whoami) && $HOME | `cmd`' >/dev/null
PROMPT_45=$(cat "${CEKERNEL_IPC_DIR}/prompt-45.txt")
assert_eq "metacharacters preserved" 'Value is $(whoami) && $HOME | `cmd`' "$PROMPT_45"

# ── Test 16: prompt survives file → cat → variable → argument pipeline ──
# Verifies the critical security property: special characters in prompt
# are not interpreted when passed through the file-based pipeline.
# Does not require TTY (tests the pipeline, not the `script` command).
TEST_PROMPT='capture-test with "quotes" '\''apostrophe'\'' $(not-expanded) `no-backtick` && || ; > < |'
printf '%s' "$TEST_PROMPT" > "${CEKERNEL_IPC_DIR}/prompt-eval.txt"

# Simulate what the runner script does: cat file → variable → argument
PROMPT_READ=$(cat "${CEKERNEL_IPC_DIR}/prompt-eval.txt")
OUTPUT=$(echo "$PROMPT_READ")
assert_eq "prompt survives file-to-variable-to-arg pipeline" "$TEST_PROMPT" "$OUTPUT"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
