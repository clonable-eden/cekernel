#!/usr/bin/env bash
# test-at-launchd.sh — Tests for scheduler/at-backends/launchd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: scheduler/at-backends/launchd.sh"

# ── Setup ──
setup() {
  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  export CEKERNEL_LAUNCHD_DIR="$(mktemp -d)"
  mkdir -p "${CEKERNEL_VAR_DIR}/runners" "${CEKERNEL_VAR_DIR}/logs"
  echo '[]' > "${CEKERNEL_VAR_DIR}/schedules.json"

  source "${CEKERNEL_DIR}/scripts/scheduler/at-backends/launchd.sh"
  source "${CEKERNEL_DIR}/scripts/scheduler/wrapper.sh"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR" "$CEKERNEL_LAUNCHD_DIR"
}

# ═══════════════════════════════════════
# _at_parse_datetime
# ═══════════════════════════════════════

# ── Test 1: parse standard datetime ──
setup
_at_parse_datetime "2026-03-15T09:30"
assert_eq "parse month" "3" "$_AT_MONTH"
assert_eq "parse day" "15" "$_AT_DAY"
assert_eq "parse hour" "9" "$_AT_HOUR"
assert_eq "parse minute" "30" "$_AT_MINUTE"
teardown

# ── Test 2: parse midnight ──
setup
_at_parse_datetime "2026-01-01T00:00"
assert_eq "parse month midnight" "1" "$_AT_MONTH"
assert_eq "parse day midnight" "1" "$_AT_DAY"
assert_eq "parse hour midnight" "0" "$_AT_HOUR"
assert_eq "parse minute midnight" "0" "$_AT_MINUTE"
teardown

# ── Test 3: parse end of year ──
setup
_at_parse_datetime "2026-12-31T23:59"
assert_eq "parse month dec" "12" "$_AT_MONTH"
assert_eq "parse day 31" "31" "$_AT_DAY"
assert_eq "parse hour 23" "23" "$_AT_HOUR"
assert_eq "parse minute 59" "59" "$_AT_MINUTE"
teardown

# ── Test 4: parse datetime with seconds (ignored) ──
setup
_at_parse_datetime "2026-06-15T14:30:00"
assert_eq "parse month with seconds" "6" "$_AT_MONTH"
assert_eq "parse minute with seconds" "30" "$_AT_MINUTE"
teardown

# ═══════════════════════════════════════
# at_launchd_generate_plist
# ═══════════════════════════════════════

# ── Test 5: plist has correct label ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_match "plist has label" "cekernel-at-test01" "$PLIST"
teardown

# ── Test 6: plist has runner path ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_match "plist has runner path" "/tmp/runner.sh" "$PLIST"
teardown

# ── Test 7: plist has correct Month ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_match "plist has Month 3" "<key>Month</key>" "$PLIST"
teardown

# ── Test 8: plist has correct Day ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_match "plist has Day 15" "<integer>15</integer>" "$PLIST"
teardown

# ── Test 9: plist has correct Hour ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_match "plist has Hour 9" "<integer>9</integer>" "$PLIST"
teardown

# ── Test 10: plist has correct Minute ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
# Minute=0 → <integer>0</integer>
assert_match "plist has Minute 0" "<integer>0</integer>" "$PLIST"
teardown

# ── Test 11: plist uses single dict (not array) for StartCalendarInterval ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_match "plist has StartCalendarInterval" "<key>StartCalendarInterval</key>" "$PLIST"
# Should NOT have <array> wrapper (one-shot uses single dict)
if echo "$PLIST" | grep -A1 "StartCalendarInterval" | grep -q "<array>"; then
  assert_eq "no array wrapper" "dict" "array"
else
  assert_eq "no array wrapper" "dict" "dict"
fi
teardown

# ── Test 12: plist has log paths ──
setup
PLIST=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_match "plist has stdout log" "cekernel-at-test01.stdout.log" "$PLIST"
assert_match "plist has stderr log" "cekernel-at-test01.stderr.log" "$PLIST"
teardown

# ═══════════════════════════════════════
# _at_launchd_inject_cleanup
# ═══════════════════════════════════════

# ── Test 13: inject cleanup adds bootout ──
setup
schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
RUNNER="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
_at_launchd_inject_cleanup "cekernel-at-test01" "$RUNNER"
CONTENT=$(cat "$RUNNER")
assert_match "runner has bootout" "launchctl bootout" "$CONTENT"
assert_match "runner has id in bootout" "cekernel-at-test01" "$CONTENT"
teardown

# ── Test 14: inject cleanup preserves exit line ──
setup
schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
RUNNER="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
_at_launchd_inject_cleanup "cekernel-at-test01" "$RUNNER"
CONTENT=$(cat "$RUNNER")
assert_match "runner still has exit" "exit" "$CONTENT"
teardown

# ── Test 15: bootout appears before exit ──
setup
schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
RUNNER="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
_at_launchd_inject_cleanup "cekernel-at-test01" "$RUNNER"
BOOTOUT_LINE=$(grep -n "launchctl bootout" "$RUNNER" | head -1 | cut -d: -f1)
EXIT_LINE=$(grep -n "^exit " "$RUNNER" | head -1 | cut -d: -f1)
if [[ "$BOOTOUT_LINE" -lt "$EXIT_LINE" ]]; then
  assert_eq "bootout before exit" "1" "1"
else
  assert_eq "bootout before exit" "before" "after"
fi
teardown

# ── Test 16: inject cleanup keeps 700 permissions ──
setup
schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
RUNNER="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
_at_launchd_inject_cleanup "cekernel-at-test01" "$RUNNER"
if [[ "$(uname)" == "Darwin" ]]; then
  PERMS=$(stat -f '%Lp' "$RUNNER")
else
  PERMS=$(stat -c '%a' "$RUNNER")
fi
assert_eq "runner has 700 after inject" "700" "$PERMS"
teardown

# ═══════════════════════════════════════
# at_launchd_register / cancel (mocked launchctl)
# ═══════════════════════════════════════

# ── Test 17: register creates plist and returns os_ref ──
setup
_MOCK_BIN="$(mktemp -d)"
echo '#!/bin/bash' > "${_MOCK_BIN}/launchctl" && chmod +x "${_MOCK_BIN}/launchctl"
export PATH="${_MOCK_BIN}:${PATH}"

schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
RUNNER="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
OS_REF=$(at_launchd_register "cekernel-at-test01" "2026-03-15T09:00" "$RUNNER")
assert_eq "os_ref is id" "cekernel-at-test01" "$OS_REF"
assert_file_exists "plist created" "${CEKERNEL_LAUNCHD_DIR}/cekernel-at-test01.plist"
rm -rf "$_MOCK_BIN"
teardown

# ── Test 18: register injects bootout into runner ──
setup
_MOCK_BIN="$(mktemp -d)"
echo '#!/bin/bash' > "${_MOCK_BIN}/launchctl" && chmod +x "${_MOCK_BIN}/launchctl"
export PATH="${_MOCK_BIN}:${PATH}"

schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
RUNNER="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
at_launchd_register "cekernel-at-test01" "2026-03-15T09:00" "$RUNNER" >/dev/null
CONTENT=$(cat "$RUNNER")
assert_match "register injects bootout" "launchctl bootout" "$CONTENT"
rm -rf "$_MOCK_BIN"
teardown

# ── Test 19: cancel removes plist ──
setup
_MOCK_BIN="$(mktemp -d)"
echo '#!/bin/bash' > "${_MOCK_BIN}/launchctl" && chmod +x "${_MOCK_BIN}/launchctl"
export PATH="${_MOCK_BIN}:${PATH}"

schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
RUNNER="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
at_launchd_register "cekernel-at-test01" "2026-03-15T09:00" "$RUNNER" >/dev/null
at_launchd_cancel "cekernel-at-test01"
assert_not_exists "plist removed" "${CEKERNEL_LAUNCHD_DIR}/cekernel-at-test01.plist"
rm -rf "$_MOCK_BIN"
teardown

report_results
