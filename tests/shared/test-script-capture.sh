#!/usr/bin/env bash
# test-script-capture.sh — Tests for script-capture.sh helper
#
# Tests the write_runner_script function that generates runner scripts
# for stdout/stderr capture, with prompt passed via file (no escaping needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: script-capture"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-script-capture-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Source script-capture.sh ──
source "${CEKERNEL_DIR}/scripts/shared/script-capture.sh"

# ── Test 1: write_runner_script creates runner file ──
RUNNER=$(write_runner_script "42" "/tmp/worktree" "test-session" "worker" "hello world" "/tmp/test.log")
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

# ── Test 6: Runner script contains session ID export ──
assert_match "runner contains session ID" "CEKERNEL_SESSION_ID='test-session'" "$(cat "$RUNNER")"

# ── Test 7: Runner script contains agent name ──
assert_match "runner contains agent name" "agent worker" "$(cat "$RUNNER")"

# ── Test 8: Runner script contains log file path ──
assert_match "runner contains log file" "/tmp/test.log" "$(cat "$RUNNER")"

# ── Test 9: Runner script reads prompt from file (not embedded) ──
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

# ── Test 10: Runner script unsets Claude Code env vars ──
assert_match "runner unsets CLAUDECODE" "unset CLAUDECODE" "$RUNNER_CONTENT"

# ── Test 11: Prompt with double quotes ──
write_runner_script "43" "/tmp/wt" "s" "worker" 'Resolve "issue"' "/tmp/l.log" >/dev/null
PROMPT_43=$(cat "${CEKERNEL_IPC_DIR}/prompt-43.txt")
assert_eq "double quotes preserved" 'Resolve "issue"' "$PROMPT_43"

# ── Test 12: Prompt with single quotes ──
write_runner_script "44" "/tmp/wt" "s" "worker" "It's a test" "/tmp/l.log" >/dev/null
PROMPT_44=$(cat "${CEKERNEL_IPC_DIR}/prompt-44.txt")
assert_eq "single quotes preserved" "It's a test" "$PROMPT_44"

# ── Test 13: Prompt with shell metacharacters ──
write_runner_script "45" "/tmp/wt" "s" "worker" 'Value is $(whoami) && $HOME | `cmd`' "/tmp/l.log" >/dev/null
PROMPT_45=$(cat "${CEKERNEL_IPC_DIR}/prompt-45.txt")
assert_eq "metacharacters preserved" 'Value is $(whoami) && $HOME | `cmd`' "$PROMPT_45"

# ── Test 14: prompt survives file → cat → variable → argument pipeline ──
# Verifies the critical security property: special characters in prompt
# are not interpreted when passed through the file-based pipeline.
# Does not require TTY (tests the pipeline, not the `script` command).
TEST_PROMPT='capture-test with "quotes" '\''apostrophe'\'' $(not-expanded) `no-backtick` && || ; > < |'
printf '%s' "$TEST_PROMPT" > "${CEKERNEL_IPC_DIR}/prompt-eval.txt"

# Simulate what the runner script does: cat file → variable → argument
PROMPT_READ=$(cat "${CEKERNEL_IPC_DIR}/prompt-eval.txt")
OUTPUT=$(echo "$PROMPT_READ")
assert_eq "prompt survives file-to-variable-to-arg pipeline" "$TEST_PROMPT" "$OUTPUT"

# ── Test 15: ensure_log_dir creates directory ──
TEST_LOG_DIR="${CEKERNEL_IPC_DIR}/logs"
rm -rf "$TEST_LOG_DIR"
ensure_log_dir
assert_dir_exists "ensure_log_dir creates logs directory" "$TEST_LOG_DIR"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
