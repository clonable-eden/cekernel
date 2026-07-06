#!/usr/bin/env bats
# at-backends.bats — bats-core tests for scripts/scheduler/at-backends/ (ADR-0017 Decision 4)
#
# Both /at OS backends in one file:
#   - atd.sh (Linux/WSL): at/atq/atrm, mocked statefully via PATH shims
#   - launchd.sh (macOS): plist generation + launchctl, mocked via PATH shims
# Consolidates legacy tests/scheduler/test-at-atd.sh and test-at-launchd.sh.

load '../helpers/assertions'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  export CEKERNEL_VAR_DIR="${BATS_TEST_TMPDIR}/var"
  mkdir -p "${CEKERNEL_VAR_DIR}/runners" "${CEKERNEL_VAR_DIR}/logs"
  echo '[]' > "${CEKERNEL_VAR_DIR}/schedules.json"

  export CEKERNEL_LAUNCHD_DIR="${BATS_TEST_TMPDIR}/launchd"
  mkdir -p "$CEKERNEL_LAUNCHD_DIR"

  # --bare preflight requires an auth path (wrapper generation in launchd tests)
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS

  source "${CEKERNEL_DIR}/scripts/scheduler/at-backends/atd.sh"
  source "${CEKERNEL_DIR}/scripts/scheduler/at-backends/launchd.sh"
  source "${CEKERNEL_DIR}/scripts/scheduler/wrapper.sh"
}

# Stateful at/atq/atrm shims backed by a queue file: `at` assigns
# incrementing job numbers, `atq` lists pending jobs, `atrm` removes one.
mock_atd() {
  ATQ_FILE="${BATS_TEST_TMPDIR}/atq"
  : > "$ATQ_FILE"

  mock_bin at "cat > /dev/null
COUNTER='${BATS_TEST_TMPDIR}/atq.counter'
if [[ -f \"\$COUNTER\" ]]; then
  JOB=\$(cat \"\$COUNTER\")
else
  JOB=0
fi
JOB=\$((JOB + 1))
echo \"\$JOB\" > \"\$COUNTER\"
printf '%s\tMon Mar 15 09:00:00 2026 = user\n' \"\$JOB\" >> '${ATQ_FILE}'
echo \"job \$JOB at Mon Mar 15 09:00:00 2026\" >&2"

  mock_bin atq "cat '${ATQ_FILE}'"

  mock_bin atrm "grep -v \"^\${1}[[:space:]]\" '${ATQ_FILE}' > '${ATQ_FILE}.tmp' || true
mv '${ATQ_FILE}.tmp' '${ATQ_FILE}'"
}

# ═══════════════════════════════════════
# atd backend — _at_datetime_to_at_time
# ═══════════════════════════════════════

@test "atd: datetime converts to at -t format" {
  assert_eq "datetime to at_time" "202603150900" "$(_at_datetime_to_at_time "2026-03-15T09:00")"
}

@test "atd: midnight converts to at -t format" {
  assert_eq "midnight to at_time" "202601010000" "$(_at_datetime_to_at_time "2026-01-01T00:00")"
}

@test "atd: datetime with seconds is truncated" {
  assert_eq "with seconds to at_time" "202612312359" "$(_at_datetime_to_at_time "2026-12-31T23:59:30")"
}

# ═══════════════════════════════════════
# atd backend — register / is_registered / cancel
# ═══════════════════════════════════════

@test "atd: register returns job number" {
  mock_atd
  assert_eq "register returns job 1" "1" \
    "$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")"
}

@test "atd: second register returns incremented job" {
  mock_atd
  at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh" >/dev/null
  assert_eq "second register returns job 2" "2" \
    "$(at_atd_register "cekernel-at-test02" "2026-03-16T10:00" "/tmp/runner2.sh")"
}

@test "atd: is_registered returns true for pending job" {
  mock_atd
  local job
  job=$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
  at_atd_is_registered "$job"
}

@test "atd: is_registered returns false for nonexistent job" {
  mock_atd
  run at_atd_is_registered "999"
  [[ "$status" -ne 0 ]]
}

@test "atd: cancel removes job" {
  mock_atd
  local job
  job=$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
  at_atd_cancel "$job"
  run at_atd_is_registered "$job"
  [[ "$status" -ne 0 ]]
}

@test "atd: cancel preserves other jobs" {
  mock_atd
  local job1 job2
  job1=$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
  job2=$(at_atd_register "cekernel-at-test02" "2026-03-16T10:00" "/tmp/runner2.sh")
  at_atd_cancel "$job1"
  at_atd_is_registered "$job2"
}

@test "atd: cancel nonexistent job is silent" {
  mock_atd
  run at_atd_cancel "999"
  assert_eq "cancel nonexistent succeeds" "0" "$status"
}

# ═══════════════════════════════════════
# launchd backend — _at_parse_datetime
# ═══════════════════════════════════════

@test "launchd: parse standard datetime" {
  _at_parse_datetime "2026-03-15T09:30"
  assert_eq "parse month" "3" "$_AT_MONTH"
  assert_eq "parse day" "15" "$_AT_DAY"
  assert_eq "parse hour" "9" "$_AT_HOUR"
  assert_eq "parse minute" "30" "$_AT_MINUTE"
}

@test "launchd: parse midnight" {
  _at_parse_datetime "2026-01-01T00:00"
  assert_eq "parse month midnight" "1" "$_AT_MONTH"
  assert_eq "parse day midnight" "1" "$_AT_DAY"
  assert_eq "parse hour midnight" "0" "$_AT_HOUR"
  assert_eq "parse minute midnight" "0" "$_AT_MINUTE"
}

@test "launchd: parse end of year" {
  _at_parse_datetime "2026-12-31T23:59"
  assert_eq "parse month dec" "12" "$_AT_MONTH"
  assert_eq "parse day 31" "31" "$_AT_DAY"
  assert_eq "parse hour 23" "23" "$_AT_HOUR"
  assert_eq "parse minute 59" "59" "$_AT_MINUTE"
}

@test "launchd: parse datetime with seconds (ignored)" {
  _at_parse_datetime "2026-06-15T14:30:00"
  assert_eq "parse month with seconds" "6" "$_AT_MONTH"
  assert_eq "parse minute with seconds" "30" "$_AT_MINUTE"
}

# ═══════════════════════════════════════
# launchd backend — at_launchd_generate_plist
# ═══════════════════════════════════════

@test "launchd: plist has label, runner path, and calendar fields" {
  local plist
  plist=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
  assert_match "plist has label" "cekernel-at-test01" "$plist"
  assert_match "plist has runner path" "/tmp/runner.sh" "$plist"
  assert_match "plist has Month key" "<key>Month</key>" "$plist"
  assert_match "plist has Day 15" "<integer>15</integer>" "$plist"
  assert_match "plist has Hour 9" "<integer>9</integer>" "$plist"
  assert_match "plist has Minute 0" "<integer>0</integer>" "$plist"
}

@test "launchd: plist uses single dict (not array) for StartCalendarInterval" {
  local plist
  plist=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
  assert_match "plist has StartCalendarInterval" "<key>StartCalendarInterval</key>" "$plist"
  # One-shot schedule uses a single dict — no <array> wrapper
  if echo "$plist" | grep -A1 "StartCalendarInterval" | grep -q "<array>"; then
    assert_eq "no array wrapper" "dict" "array"
  fi
}

@test "launchd: plist has log paths" {
  local plist
  plist=$(at_launchd_generate_plist "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
  assert_match "plist has stdout log" "cekernel-at-test01.stdout.log" "$plist"
  assert_match "plist has stderr log" "cekernel-at-test01.stderr.log" "$plist"
}

# ═══════════════════════════════════════
# launchd backend — _at_launchd_inject_cleanup
# ═══════════════════════════════════════

@test "launchd: inject cleanup adds bootout before exit" {
  schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
  local runner="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
  _at_launchd_inject_cleanup "cekernel-at-test01" "$runner"

  local content
  content=$(cat "$runner")
  assert_match "runner has bootout" "launchctl bootout" "$content"
  assert_match "runner has id in bootout" "cekernel-at-test01" "$content"
  assert_match "runner still has exit" "exit" "$content"

  local bootout_line exit_line
  bootout_line=$(grep -n "launchctl bootout" "$runner" | head -1 | cut -d: -f1)
  exit_line=$(grep -n "^exit " "$runner" | head -1 | cut -d: -f1)
  [[ "$bootout_line" -lt "$exit_line" ]]
}

@test "launchd: inject cleanup keeps 700 permissions" {
  schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
  local runner="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"
  _at_launchd_inject_cleanup "cekernel-at-test01" "$runner"

  local perms
  if [[ "$(uname)" == "Darwin" ]]; then
    perms=$(stat -f '%Lp' "$runner")
  else
    perms=$(stat -c '%a' "$runner")
  fi
  assert_eq "runner has 700 after inject" "700" "$perms"
}

# ═══════════════════════════════════════
# launchd backend — register / cancel (mocked launchctl)
# ═══════════════════════════════════════

@test "launchd: register creates plist and returns os_ref" {
  mock_bin launchctl ':'
  schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
  local runner="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"

  local os_ref
  os_ref=$(at_launchd_register "cekernel-at-test01" "2026-03-15T09:00" "$runner")
  assert_eq "os_ref is id" "cekernel-at-test01" "$os_ref"
  assert_file_exists "plist created" "${CEKERNEL_LAUNCHD_DIR}/cekernel-at-test01.plist"
}

@test "launchd: register injects bootout into runner" {
  mock_bin launchctl ':'
  schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
  local runner="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"

  at_launchd_register "cekernel-at-test01" "2026-03-15T09:00" "$runner" >/dev/null
  assert_match "register injects bootout" "launchctl bootout" "$(cat "$runner")"
}

@test "launchd: cancel removes plist" {
  mock_bin launchctl ':'
  schedule_generate_wrapper "cekernel-at-test01" "/tmp/repo" "/usr/bin:/bin" "test prompt"
  local runner="${CEKERNEL_VAR_DIR}/runners/cekernel-at-test01.sh"

  at_launchd_register "cekernel-at-test01" "2026-03-15T09:00" "$runner" >/dev/null
  at_launchd_cancel "cekernel-at-test01"
  assert_not_exists "plist removed" "${CEKERNEL_LAUNCHD_DIR}/cekernel-at-test01.plist"
}
