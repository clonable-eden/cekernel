#!/usr/bin/env bash
# test-cron-launchd.sh — Tests for scheduler/cron-backends/launchd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: scheduler/cron-backends/launchd.sh"

# ── Setup ──
setup() {
  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  export CEKERNEL_LAUNCHD_DIR="$(mktemp -d)"
  mkdir -p "${CEKERNEL_VAR_DIR}/logs"
  source "${CEKERNEL_DIR}/scripts/scheduler/cron-backends/launchd.sh"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR" "$CEKERNEL_LAUNCHD_DIR"
}

# ═══════════════════════════════════════
# _expand_cron_field tests
# ═══════════════════════════════════════

# ── Test 1: wildcard returns empty ──
setup
RESULT=$(_expand_cron_field "*" 0 59)
assert_eq "wildcard returns empty" "" "$RESULT"
teardown

# ── Test 2: single value ──
setup
RESULT=$(_expand_cron_field "5" 0 59)
assert_eq "single value" "5" "$RESULT"
teardown

# ── Test 3: range ──
setup
RESULT=$(_expand_cron_field "1-5" 0 6)
assert_eq "range 1-5" "1 2 3 4 5" "$RESULT"
teardown

# ── Test 4: step with wildcard ──
setup
RESULT=$(_expand_cron_field "*/15" 0 59)
assert_eq "*/15 for minutes" "0 15 30 45" "$RESULT"
teardown

# ── Test 5: step with wildcard for hours ──
setup
RESULT=$(_expand_cron_field "*/6" 0 23)
assert_eq "*/6 for hours" "0 6 12 18" "$RESULT"
teardown

# ── Test 6: range with step ──
setup
RESULT=$(_expand_cron_field "1-5/2" 0 6)
assert_eq "1-5/2" "1 3 5" "$RESULT"
teardown

# ── Test 7: comma-separated list ──
setup
RESULT=$(_expand_cron_field "1,3,5" 0 6)
assert_eq "list 1,3,5" "1 3 5" "$RESULT"
teardown

# ── Test 8: mixed list with range ──
setup
RESULT=$(_expand_cron_field "1-3,5" 0 6)
assert_eq "mixed 1-3,5" "1 2 3 5" "$RESULT"
teardown

# ═══════════════════════════════════════
# _cron_to_calendar_intervals tests
# ═══════════════════════════════════════

# ── Test 9: simple daily schedule ──
setup
RESULT=$(_cron_to_calendar_intervals "0 9 * * *")
COUNT=$(echo "$RESULT" | jq 'length')
assert_eq "0 9 * * * produces 1 interval" "1" "$COUNT"
MIN=$(echo "$RESULT" | jq '.[0].Minute')
HOUR=$(echo "$RESULT" | jq '.[0].Hour')
assert_eq "minute is 0" "0" "$MIN"
assert_eq "hour is 9" "9" "$HOUR"
teardown

# ── Test 10: weekday range ──
setup
RESULT=$(_cron_to_calendar_intervals "0 9 * * 1-5")
COUNT=$(echo "$RESULT" | jq 'length')
assert_eq "0 9 * * 1-5 produces 5 intervals" "5" "$COUNT"
FIRST_WD=$(echo "$RESULT" | jq '.[0].Weekday')
LAST_WD=$(echo "$RESULT" | jq '.[-1].Weekday')
assert_eq "first weekday is 1" "1" "$FIRST_WD"
assert_eq "last weekday is 5" "5" "$LAST_WD"
teardown

# ── Test 11: minute step ──
setup
RESULT=$(_cron_to_calendar_intervals "*/15 * * * *")
COUNT=$(echo "$RESULT" | jq 'length')
assert_eq "*/15 * * * * produces 4 intervals" "4" "$COUNT"
MINS=$(echo "$RESULT" | jq -c '[.[].Minute] | sort')
assert_eq "minutes are 0,15,30,45" "[0,15,30,45]" "$MINS"
teardown

# ── Test 12: combined minute + hour step ──
setup
RESULT=$(_cron_to_calendar_intervals "30 */6 * * *")
COUNT=$(echo "$RESULT" | jq 'length')
assert_eq "30 */6 * * * produces 4 intervals" "4" "$COUNT"
ALL_MIN=$(echo "$RESULT" | jq -c '[.[].Minute] | unique')
assert_eq "all minutes are 30" "[30]" "$ALL_MIN"
HOURS=$(echo "$RESULT" | jq -c '[.[].Hour] | sort')
assert_eq "hours are 0,6,12,18" "[0,6,12,18]" "$HOURS"
teardown

# ── Test 13: day-of-week 7 normalized to 0 ──
setup
RESULT=$(_cron_to_calendar_intervals "0 9 * * 7")
WD=$(echo "$RESULT" | jq '.[0].Weekday')
assert_eq "weekday 7 normalized to 0" "0" "$WD"
teardown

# ═══════════════════════════════════════
# cron_launchd_generate_plist tests
# ═══════════════════════════════════════

TEST_ID="cekernel-cron-test01"
TEST_RUNNER="/usr/local/var/cekernel/runners/${TEST_ID}.sh"

# ── Test 14: plist is valid XML ──
setup
PLIST=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER")
if echo "$PLIST" | head -1 | grep -q '<?xml'; then
  assert_eq "plist starts with XML declaration" "1" "1"
else
  assert_eq "plist starts with XML declaration" "1" "0"
fi
teardown

# ── Test 15: plist contains Label ──
setup
PLIST=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * *" "$TEST_RUNNER")
assert_match "plist contains Label" "$TEST_ID" "$PLIST"
teardown

# ── Test 16: plist contains runner path ──
setup
PLIST=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * *" "$TEST_RUNNER")
assert_match "plist contains runner path" "$TEST_RUNNER" "$PLIST"
teardown

# ── Test 17: plist contains StartCalendarInterval ──
setup
PLIST=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * *" "$TEST_RUNNER")
assert_match "plist contains StartCalendarInterval" "StartCalendarInterval" "$PLIST"
teardown

# ── Test 18: plist contains log paths ──
setup
PLIST=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * *" "$TEST_RUNNER")
assert_match "plist contains stdout log" "StandardOutPath" "$PLIST"
assert_match "plist contains stderr log" "StandardErrorPath" "$PLIST"
teardown

# ═══════════════════════════════════════
# cron_launchd_register / cancel tests
# ═══════════════════════════════════════

# ── Test 19: register creates plist file ──
setup
# Mock launchctl to avoid side effects
launchctl() { return 0; }
export -f launchctl
cron_launchd_register "$TEST_ID" "0 9 * * *" "$TEST_RUNNER"
assert_file_exists "plist file created" "${CEKERNEL_LAUNCHD_DIR}/${TEST_ID}.plist"
unset -f launchctl
teardown

# ── Test 20: cancel removes plist file ──
setup
launchctl() { return 0; }
export -f launchctl
cron_launchd_register "$TEST_ID" "0 9 * * *" "$TEST_RUNNER"
cron_launchd_cancel "$TEST_ID"
assert_not_exists "plist file removed" "${CEKERNEL_LAUNCHD_DIR}/${TEST_ID}.plist"
unset -f launchctl
teardown

report_results
