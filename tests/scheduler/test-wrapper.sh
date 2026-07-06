#!/usr/bin/env bash
# test-wrapper.sh — Tests for scheduler/wrapper.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WRAPPER_SCRIPT="${CEKERNEL_DIR}/scripts/scheduler/wrapper.sh"

echo "test: scheduler/wrapper.sh"

# ── Setup ──
setup() {
  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  mkdir -p "${CEKERNEL_VAR_DIR}/runners"
  echo '[]' > "${CEKERNEL_VAR_DIR}/schedules.json"
  # --bare preflight requires an auth path (never reads OAuth/keychain)
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS
  source "$WRAPPER_SCRIPT"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR"
}

TEST_ID="cekernel-cron-test01"
TEST_REPO="/tmp/test-repo"
TEST_PATH="/opt/homebrew/bin:/usr/bin:/bin"
TEST_PROMPT="/dispatch --env headless --label ready"

# ── Test 1: generated file exists ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
assert_file_exists "wrapper file exists" "$RUNNER"
teardown

# ── Test 2: permissions are 700 ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
if [[ "$(uname)" == "Darwin" ]]; then
  PERMS=$(stat -f '%Lp' "$RUNNER")
else
  PERMS=$(stat -c '%a' "$RUNNER")
fi
assert_eq "wrapper has 700 permissions" "700" "$PERMS"
teardown

# ── Test 3: set -euo pipefail is present ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "contains set -euo pipefail" "set -euo pipefail" "$CONTENT"
teardown

# ── Test 4: PATH is embedded ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "PATH is embedded" "/opt/homebrew/bin:/usr/bin:/bin" "$CONTENT"
teardown

# ── Test 5: CEKERNEL_DIR is embedded ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "CEKERNEL_DIR is embedded" "CEKERNEL_DIR=" "$CONTENT"
teardown

# ── Test 6: registry.sh source path exists ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
# Extract the source line and check the referenced file exists
SOURCE_PATH=$(grep 'source.*registry.sh' "$RUNNER" | sed 's/.*source "\(.*\)"/\1/' | sed "s|\${CEKERNEL_DIR}|${CEKERNEL_DIR}|")
assert_file_exists "registry.sh source path exists" "$SOURCE_PATH"
teardown

# ── Test 7: if/else pattern for claude -p (set -e safe) ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "uses if/else pattern" "if cd .* && claude -p" "$CONTENT"
assert_match "has else clause" "else" "$CONTENT"
teardown

# ── Test 8: sources desktop-notify.sh shared helper ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "sources desktop-notify.sh" "desktop-notify.sh" "$CONTENT"
teardown

# ── Test 9: uses desktop_notify function for failure notification ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "uses desktop_notify function" "desktop_notify" "$CONTENT"
teardown

# ── Test 10: claude -p output goes to <id>.run.log (not schedule.log) ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "claude output goes to run.log" "${TEST_ID}.run.log" "$CONTENT"
teardown

# ── Test 11: syslog START line written to schedule.log ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "syslog START in schedule.log" 'schedule.log' "$CONTENT"
assert_match "START line format" 'START' "$CONTENT"
teardown

# ── Test 12: syslog END line written to schedule.log ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "END line format" 'END' "$CONTENT"
teardown

# ── Test 13: duration tracking via SECONDS ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "uses SECONDS for duration" 'SECONDS' "$CONTENT"
teardown

# ── Test 14: no --max-budget-usd ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
if echo "$CONTENT" | grep -q "max-budget-usd"; then
  assert_eq "--max-budget-usd is absent" "absent" "present"
else
  assert_eq "--max-budget-usd is absent" "absent" "absent"
fi
teardown

# ── Test 15: no --no-session-persistence ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
if echo "$CONTENT" | grep -q "no-session-persistence"; then
  assert_eq "--no-session-persistence is absent" "absent" "present"
else
  assert_eq "--no-session-persistence is absent" "absent" "absent"
fi
teardown

# ── Test 16: registry update_status is called ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "calls schedule_registry_update_status" "schedule_registry_update_status" "$CONTENT"
teardown

# ── Test 17: claude is invoked with explicit --bare context (ADR-0016 Phase 0) ──
setup
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "claude invoked with --bare" "claude -p --bare" "$CONTENT"
assert_match "plugin dir embedded" "--plugin-dir ${CEKERNEL_DIR}" "$CONTENT"
assert_match "repo embedded as --add-dir" "--add-dir ${TEST_REPO}" "$CONTENT"
teardown

# ── Test 18: CEKERNEL_CLAUDE_SETTINGS at generation time → --settings embedded ──
# Required for cron/at: exported env vars don't reach the generated runner,
# so auth must travel as a captured --settings path (apiKeyHelper).
setup
SETTINGS_FILE="${CEKERNEL_VAR_DIR}/claude-settings.json"
echo '{}' > "$SETTINGS_FILE"
export CEKERNEL_CLAUDE_SETTINGS="$SETTINGS_FILE"
schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT"
RUNNER="${CEKERNEL_VAR_DIR}/runners/${TEST_ID}.sh"
CONTENT=$(cat "$RUNNER")
assert_match "--settings embedded in runner" "--settings ${SETTINGS_FILE}" "$CONTENT"
unset CEKERNEL_CLAUDE_SETTINGS
teardown

# ── Test 19: generation fails fast without --bare-compatible auth ──
setup
EXIT_CODE=0
(
  unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS
  schedule_generate_wrapper "$TEST_ID" "$TEST_REPO" "$TEST_PATH" "$TEST_PROMPT" 2>/dev/null
) || EXIT_CODE=$?
assert_eq "generation fails without bare auth" "1" "$EXIT_CODE"
teardown

report_results
