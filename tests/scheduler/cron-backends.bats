#!/usr/bin/env bats
# cron-backends.bats — bats-core tests for scripts/scheduler/cron-backends/ (ADR-0017 Decision 4)
#
# Both /cron OS backends in one file:
#   - crontab.sh (Linux/WSL): crontab entries via the _CRON_CRONTAB_FILE test hook
#   - launchd.sh (macOS): cron-expression → StartCalendarInterval conversion + launchctl
# Consolidates legacy tests/scheduler/test-cron-crontab.sh and test-cron-launchd.sh.
# The legacy launchctl shell-function override is replaced by a PATH shim
# (mock_bin) per ADR-0017 Decision 2.

load '../helpers/assertions'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  export CEKERNEL_VAR_DIR="${BATS_TEST_TMPDIR}/var"
  mkdir -p "${CEKERNEL_VAR_DIR}/logs"

  export CEKERNEL_LAUNCHD_DIR="${BATS_TEST_TMPDIR}/launchd"
  mkdir -p "$CEKERNEL_LAUNCHD_DIR"

  # crontab file hook (no real crontab reads/writes)
  export _CRON_CRONTAB_FILE="${BATS_TEST_TMPDIR}/crontab"
  echo "" > "$_CRON_CRONTAB_FILE"

  source "${CEKERNEL_DIR}/scripts/scheduler/cron-backends/crontab.sh"
  source "${CEKERNEL_DIR}/scripts/scheduler/cron-backends/launchd.sh"

  TEST_ID="cekernel-cron-test01"
  TEST_RUNNER="/usr/local/var/cekernel/runners/${TEST_ID}.sh"
}

# ═══════════════════════════════════════
# crontab backend — entry generation
# ═══════════════════════════════════════

@test "crontab: generate line contains schedule and runner path" {
  local result
  result=$(cron_crontab_generate_line "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER")
  assert_match "crontab line contains schedule" "0 9 \* \* 1-5" "$result"
  assert_match "crontab line contains runner path" "$TEST_RUNNER" "$result"
}

@test "crontab: generate entry has comment with ID" {
  local result
  result=$(cron_crontab_generate_entry "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER")
  assert_match "entry has comment with ID" "# ${TEST_ID}" "$result"
}

# ═══════════════════════════════════════
# crontab backend — register / cancel / is_registered
# ═══════════════════════════════════════

@test "crontab: register adds entry to crontab" {
  cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
  local content
  content=$(cat "$_CRON_CRONTAB_FILE")
  assert_match "crontab contains ID comment" "$TEST_ID" "$content"
  assert_match "crontab contains schedule" "0 9 \* \* 1-5" "$content"
}

@test "crontab: register preserves existing entries" {
  echo "*/5 * * * * /usr/local/bin/existing-job.sh" > "$_CRON_CRONTAB_FILE"
  cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
  local content
  content=$(cat "$_CRON_CRONTAB_FILE")
  assert_match "preserves existing entry" "existing-job" "$content"
  assert_match "adds new entry" "$TEST_ID" "$content"
}

@test "crontab: cancel removes entry from crontab" {
  cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
  cron_crontab_cancel "$TEST_ID"
  run grep "$TEST_ID" "$_CRON_CRONTAB_FILE"
  [[ "$status" -ne 0 ]]
}

@test "crontab: cancel preserves other entries" {
  echo "*/5 * * * * /usr/local/bin/existing-job.sh" > "$_CRON_CRONTAB_FILE"
  cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
  cron_crontab_cancel "$TEST_ID"
  assert_match "other entries preserved after cancel" "existing-job" "$(cat "$_CRON_CRONTAB_FILE")"
}

@test "crontab: is_registered returns 0 for registered entry" {
  cron_crontab_register "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER"
  cron_crontab_is_registered "$TEST_ID"
}

@test "crontab: is_registered returns 1 for unregistered entry" {
  run cron_crontab_is_registered "$TEST_ID"
  [[ "$status" -ne 0 ]]
}

@test "crontab: cancel nonexistent entry is idempotent" {
  run cron_crontab_cancel "nonexistent-id"
  assert_eq "cancel nonexistent is idempotent" "0" "$status"
}

# ═══════════════════════════════════════
# launchd backend — _expand_cron_field
# ═══════════════════════════════════════

@test "launchd: wildcard field expands to empty" {
  assert_eq "wildcard returns empty" "" "$(_expand_cron_field "*" 0 59)"
}

@test "launchd: single value field" {
  assert_eq "single value" "5" "$(_expand_cron_field "5" 0 59)"
}

@test "launchd: range field" {
  assert_eq "range 1-5" "1 2 3 4 5" "$(_expand_cron_field "1-5" 0 6)"
}

@test "launchd: step with wildcard (minutes)" {
  assert_eq "*/15 for minutes" "0 15 30 45" "$(_expand_cron_field "*/15" 0 59)"
}

@test "launchd: step with wildcard (hours)" {
  assert_eq "*/6 for hours" "0 6 12 18" "$(_expand_cron_field "*/6" 0 23)"
}

@test "launchd: range with step" {
  assert_eq "1-5/2" "1 3 5" "$(_expand_cron_field "1-5/2" 0 6)"
}

@test "launchd: comma-separated list" {
  assert_eq "list 1,3,5" "1 3 5" "$(_expand_cron_field "1,3,5" 0 6)"
}

@test "launchd: mixed list with range" {
  assert_eq "mixed 1-3,5" "1 2 3 5" "$(_expand_cron_field "1-3,5" 0 6)"
}

# ═══════════════════════════════════════
# launchd backend — _cron_to_calendar_intervals
# ═══════════════════════════════════════

@test "launchd: simple daily schedule produces one interval" {
  local result
  result=$(_cron_to_calendar_intervals "0 9 * * *")
  assert_eq "0 9 * * * produces 1 interval" "1" "$(echo "$result" | jq 'length')"
  assert_eq "minute is 0" "0" "$(echo "$result" | jq '.[0].Minute')"
  assert_eq "hour is 9" "9" "$(echo "$result" | jq '.[0].Hour')"
}

@test "launchd: weekday range produces one interval per weekday" {
  local result
  result=$(_cron_to_calendar_intervals "0 9 * * 1-5")
  assert_eq "0 9 * * 1-5 produces 5 intervals" "5" "$(echo "$result" | jq 'length')"
  assert_eq "first weekday is 1" "1" "$(echo "$result" | jq '.[0].Weekday')"
  assert_eq "last weekday is 5" "5" "$(echo "$result" | jq '.[-1].Weekday')"
}

@test "launchd: minute step produces one interval per minute value" {
  local result
  result=$(_cron_to_calendar_intervals "*/15 * * * *")
  assert_eq "*/15 * * * * produces 4 intervals" "4" "$(echo "$result" | jq 'length')"
  assert_eq "minutes are 0,15,30,45" "[0,15,30,45]" "$(echo "$result" | jq -c '[.[].Minute] | sort')"
}

@test "launchd: combined minute + hour step" {
  local result
  result=$(_cron_to_calendar_intervals "30 */6 * * *")
  assert_eq "30 */6 * * * produces 4 intervals" "4" "$(echo "$result" | jq 'length')"
  assert_eq "all minutes are 30" "[30]" "$(echo "$result" | jq -c '[.[].Minute] | unique')"
  assert_eq "hours are 0,6,12,18" "[0,6,12,18]" "$(echo "$result" | jq -c '[.[].Hour] | sort')"
}

@test "launchd: day-of-week 7 normalized to 0" {
  local result
  result=$(_cron_to_calendar_intervals "0 9 * * 7")
  assert_eq "weekday 7 normalized to 0" "0" "$(echo "$result" | jq '.[0].Weekday')"
}

# ═══════════════════════════════════════
# launchd backend — cron_launchd_generate_plist
# ═══════════════════════════════════════

@test "launchd: plist starts with XML declaration" {
  local plist
  plist=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * 1-5" "$TEST_RUNNER")
  echo "$plist" | head -1 | grep -q '<?xml'
}

@test "launchd: plist contains label, runner path, and calendar interval" {
  local plist
  plist=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * *" "$TEST_RUNNER")
  assert_match "plist contains Label" "$TEST_ID" "$plist"
  assert_match "plist contains runner path" "$TEST_RUNNER" "$plist"
  assert_match "plist contains StartCalendarInterval" "StartCalendarInterval" "$plist"
}

@test "launchd: plist contains log paths" {
  local plist
  plist=$(cron_launchd_generate_plist "$TEST_ID" "0 9 * * *" "$TEST_RUNNER")
  assert_match "plist contains stdout log" "StandardOutPath" "$plist"
  assert_match "plist contains stderr log" "StandardErrorPath" "$plist"
}

# ═══════════════════════════════════════
# launchd backend — register / cancel (mocked launchctl)
# ═══════════════════════════════════════

@test "launchd: register creates plist file" {
  mock_bin launchctl ':'
  cron_launchd_register "$TEST_ID" "0 9 * * *" "$TEST_RUNNER"
  assert_file_exists "plist file created" "${CEKERNEL_LAUNCHD_DIR}/${TEST_ID}.plist"
}

@test "launchd: cancel removes plist file" {
  mock_bin launchctl ':'
  cron_launchd_register "$TEST_ID" "0 9 * * *" "$TEST_RUNNER"
  cron_launchd_cancel "$TEST_ID"
  assert_not_exists "plist file removed" "${CEKERNEL_LAUNCHD_DIR}/${TEST_ID}.plist"
}
