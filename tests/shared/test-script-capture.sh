#!/usr/bin/env bash
# test-script-capture.sh — Tests for script-capture.sh helper
#
# Tests the build_script_capture_cmd function that wraps commands with
# the `script` command for stdout/stderr capture, handling macOS/Linux differences.
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

# ── Test 1: build_script_capture_cmd returns non-empty string ──
RESULT=$(build_script_capture_cmd "/tmp/test.log" "echo hello")
if [[ -n "$RESULT" ]]; then
  echo "  PASS: build_script_capture_cmd returns non-empty result"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: build_script_capture_cmd returned empty result"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: Result contains the log file path ──
assert_match "Result contains log file path" "/tmp/test.log" "$RESULT"

# ── Test 3: Result contains the command to execute ──
assert_match "Result contains the command" "echo hello" "$RESULT"

# ── Test 4: Result contains 'script' command ──
assert_match "Result contains script command" "script" "$RESULT"

# ── Test 5: Result uses -q flag for quiet mode ──
assert_match "Result uses -q flag" "-q" "$RESULT"

# ── Test 6: macOS format uses 'script -q <logfile> <cmd>' pattern ──
# On macOS, the format is: script -q <logfile> <cmd...>
# On Linux, the format is: script -q -c "<cmd>" <logfile>
# We test the actual platform behavior.
if [[ "$(uname -s)" == "Darwin" ]]; then
  assert_match "macOS: script -q logfile cmd" "script -q.*/tmp/test.log.*echo hello" "$RESULT"
else
  assert_match "Linux: script -q -c cmd logfile" "script -q -c.*echo hello.*/tmp/test.log" "$RESULT"
fi

# ── Test 7: Command with special characters is handled ──
RESULT2=$(build_script_capture_cmd "/tmp/special.log" "claude --agent worker 'hello world'")
assert_match "Special chars: contains claude command" "claude --agent worker" "$RESULT2"

# ── Test 8: ensure_log_dir creates log directory ──
TEST_LOG_DIR="${CEKERNEL_IPC_DIR}/logs"
rm -rf "$TEST_LOG_DIR"
ensure_log_dir
assert_dir_exists "ensure_log_dir creates logs directory" "$TEST_LOG_DIR"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
