#!/usr/bin/env bash
# test-cron-crontab.sh — Tests for scheduler/cron-backends/crontab.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: scheduler/cron-backends/crontab.sh"

# ── Setup ──
MOCK_CRONTAB=""

setup() {
  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  # Mock crontab file for testing
  MOCK_CRONTAB="$(mktemp)"
  echo "" > "$MOCK_CRONTAB"
  export _CRON_CRONTAB_FILE="$MOCK_CRONTAB"
  source "${CEKERNEL_DIR}/scripts/scheduler/cron-backends/crontab.sh"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR"
  rm -f "$MOCK_CRONTAB"
}

TEST_ID="cekernel-cron-test01"
TEST_RUNNER="/usr/local/var/cekernel/runners/${TEST_ID}.sh"

# ── Test 1: generate crontab line ──
setup
RESULT=$(cron_crontab_generate_line "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER")
assert_match "crontab line contains schedule" "0 9 \* \* 1-5" "$RESULT"
assert_match "crontab line contains runner path" "$TEST_RUNNER" "$RESULT"
teardown

# ── Test 2: crontab line has comment with ID ──
setup
RESULT=$(cron_crontab_generate_entry "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER")
assert_match "entry has comment with ID" "# ${TEST_ID}" "$RESULT"
teardown

# ── Test 3: register adds entry to crontab ──
setup
cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
CONTENT=$(cat "$MOCK_CRONTAB")
assert_match "crontab contains ID comment" "$TEST_ID" "$CONTENT"
assert_match "crontab contains schedule" "0 9 \* \* 1-5" "$CONTENT"
teardown

# ── Test 4: register preserves existing entries ──
setup
echo "*/5 * * * * /usr/local/bin/existing-job.sh" > "$MOCK_CRONTAB"
cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
CONTENT=$(cat "$MOCK_CRONTAB")
assert_match "preserves existing entry" "existing-job" "$CONTENT"
assert_match "adds new entry" "$TEST_ID" "$CONTENT"
teardown

# ── Test 5: cancel removes entry from crontab ──
setup
cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
cron_crontab_cancel "$TEST_ID"
CONTENT=$(cat "$MOCK_CRONTAB")
if echo "$CONTENT" | grep -q "$TEST_ID"; then
  assert_eq "entry removed after cancel" "removed" "still-present"
else
  assert_eq "entry removed after cancel" "removed" "removed"
fi
teardown

# ── Test 6: cancel preserves other entries ──
setup
echo "*/5 * * * * /usr/local/bin/existing-job.sh" > "$MOCK_CRONTAB"
cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
cron_crontab_cancel "$TEST_ID"
CONTENT=$(cat "$MOCK_CRONTAB")
assert_match "other entries preserved after cancel" "existing-job" "$CONTENT"
teardown

# ── Test 7: is_registered returns 0 for registered entry ──
setup
cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
if cron_crontab_is_registered "$TEST_ID"; then
  assert_eq "is_registered returns 0" "0" "0"
else
  assert_eq "is_registered returns 0" "0" "1"
fi
teardown

# ── Test 8: is_registered returns 1 for unregistered entry ──
setup
if cron_crontab_is_registered "$TEST_ID"; then
  assert_eq "is_registered returns 1 for missing" "1" "0"
else
  assert_eq "is_registered returns 1 for missing" "1" "1"
fi
teardown

# ── Test 9: cancel nonexistent entry is idempotent ──
setup
cron_crontab_cancel "nonexistent-id"
assert_eq "cancel nonexistent is idempotent" "0" "0"
teardown

report_results
