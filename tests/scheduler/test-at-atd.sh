#!/usr/bin/env bash
# test-at-atd.sh — Tests for scheduler/at-backends/atd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: scheduler/at-backends/atd.sh"

# ── Setup ──
setup() {
  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  mkdir -p "${CEKERNEL_VAR_DIR}/runners"

  source "${CEKERNEL_DIR}/scripts/scheduler/at-backends/atd.sh"

  # Mock at/atq/atrm
  export _MOCK_BIN="$(mktemp -d)"
  export _MOCK_ATQ_FILE="$(mktemp)"
  echo "" > "$_MOCK_ATQ_FILE"

  # Mock at: simulate job creation, append to atq file
  cat > "${_MOCK_BIN}/at" <<'MOCK_AT'
#!/bin/bash
# Read command from stdin (discard)
cat > /dev/null
# Increment job counter
JOB_FILE="${_MOCK_ATQ_FILE}.counter"
if [[ -f "$JOB_FILE" ]]; then
  JOB=$(cat "$JOB_FILE")
else
  JOB=0
fi
JOB=$((JOB + 1))
echo "$JOB" > "$JOB_FILE"
# Add to mock atq
echo "${JOB}	Mon Mar 15 09:00:00 2026 = user" >> "$_MOCK_ATQ_FILE"
# Output like real at
echo "job ${JOB} at Mon Mar 15 09:00:00 2026" >&2
MOCK_AT
  chmod +x "${_MOCK_BIN}/at"

  # Mock atq: cat the mock file
  cat > "${_MOCK_BIN}/atq" <<MOCK_ATQ
#!/bin/bash
cat "$_MOCK_ATQ_FILE"
MOCK_ATQ
  chmod +x "${_MOCK_BIN}/atq"

  # Mock atrm: remove entry from mock atq file
  cat > "${_MOCK_BIN}/atrm" <<MOCK_ATRM
#!/bin/bash
JOB="\$1"
if [[ -f "$_MOCK_ATQ_FILE" ]]; then
  grep -v "^\${JOB}[[:space:]]" "$_MOCK_ATQ_FILE" > "$_MOCK_ATQ_FILE.tmp" || true
  mv "$_MOCK_ATQ_FILE.tmp" "$_MOCK_ATQ_FILE"
fi
MOCK_ATRM
  chmod +x "${_MOCK_BIN}/atrm"

  export PATH="${_MOCK_BIN}:${PATH}"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR" "$_MOCK_BIN"
  rm -f "$_MOCK_ATQ_FILE" "${_MOCK_ATQ_FILE}.counter" "${_MOCK_ATQ_FILE}.tmp"
}

# ═══════════════════════════════════════
# _at_datetime_to_at_time
# ═══════════════════════════════════════

# ── Test 1: standard datetime conversion ──
setup
RESULT=$(_at_datetime_to_at_time "2026-03-15T09:00")
assert_eq "datetime to at_time" "202603150900" "$RESULT"
teardown

# ── Test 2: midnight conversion ──
setup
RESULT=$(_at_datetime_to_at_time "2026-01-01T00:00")
assert_eq "midnight to at_time" "202601010000" "$RESULT"
teardown

# ── Test 3: datetime with seconds (truncated) ──
setup
RESULT=$(_at_datetime_to_at_time "2026-12-31T23:59:30")
assert_eq "with seconds to at_time" "202612312359" "$RESULT"
teardown

# ═══════════════════════════════════════
# at_atd_register
# ═══════════════════════════════════════

# ── Test 4: register returns job number ──
setup
JOB=$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
assert_eq "register returns job 1" "1" "$JOB"
teardown

# ── Test 5: second register returns incremented job ──
setup
at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh" >/dev/null
JOB=$(at_atd_register "cekernel-at-test02" "2026-03-16T10:00" "/tmp/runner2.sh")
assert_eq "second register returns job 2" "2" "$JOB"
teardown

# ═══════════════════════════════════════
# at_atd_is_registered
# ═══════════════════════════════════════

# ── Test 6: is_registered returns true for pending job ──
setup
JOB=$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
if at_atd_is_registered "$JOB"; then
  assert_eq "is_registered true" "1" "1"
else
  assert_eq "is_registered true" "1" "0"
fi
teardown

# ── Test 7: is_registered returns false for nonexistent job ──
setup
if at_atd_is_registered "999"; then
  assert_eq "is_registered false" "0" "1"
else
  assert_eq "is_registered false" "0" "0"
fi
teardown

# ═══════════════════════════════════════
# at_atd_cancel
# ═══════════════════════════════════════

# ── Test 8: cancel removes job ──
setup
JOB=$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
at_atd_cancel "$JOB"
if at_atd_is_registered "$JOB"; then
  assert_eq "cancel removes job" "removed" "still registered"
else
  assert_eq "cancel removes job" "removed" "removed"
fi
teardown

# ── Test 9: cancel preserves other jobs ──
setup
JOB1=$(at_atd_register "cekernel-at-test01" "2026-03-15T09:00" "/tmp/runner.sh")
JOB2=$(at_atd_register "cekernel-at-test02" "2026-03-16T10:00" "/tmp/runner2.sh")
at_atd_cancel "$JOB1"
if at_atd_is_registered "$JOB2"; then
  assert_eq "other job preserved" "1" "1"
else
  assert_eq "other job preserved" "1" "0"
fi
teardown

# ── Test 10: cancel nonexistent job is silent ──
setup
at_atd_cancel "999"
assert_eq "cancel nonexistent succeeds" "0" "$?"
teardown

report_results
