#!/usr/bin/env bash
# test-preflight.sh — Tests for scheduler/preflight.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PREFLIGHT_SCRIPT="${CEKERNEL_DIR}/scripts/scheduler/preflight.sh"
RESOLVE_SCRIPT="${CEKERNEL_DIR}/scripts/scheduler/resolve-api-key.sh"

echo "test: scheduler/preflight.sh"

# Check if API key is resolvable without env var (Keychain etc.)
KEYCHAIN_AVAILABLE=0
if ANTHROPIC_API_KEY="" bash "$RESOLVE_SCRIPT" >/dev/null 2>&1; then
  KEYCHAIN_AVAILABLE=1
fi

# ── Setup: create a fake repo with .claude/settings.json ──
setup() {
  export TEST_REPO="$(mktemp -d)"
  mkdir -p "${TEST_REPO}/.claude"
  echo '{"permissions":{"allow":["Bash","Read"]}}' > "${TEST_REPO}/.claude/settings.json"

  # Create a bin dir with mock commands
  export TEST_BIN="$(mktemp -d)"
  echo '#!/bin/bash' > "${TEST_BIN}/claude" && chmod +x "${TEST_BIN}/claude"
  echo '#!/bin/bash' > "${TEST_BIN}/gh" && chmod +x "${TEST_BIN}/gh"
  echo '#!/bin/bash' > "${TEST_BIN}/git" && chmod +x "${TEST_BIN}/git"

  source "$PREFLIGHT_SCRIPT"
}

teardown() {
  rm -rf "$TEST_REPO" "$TEST_BIN"
}

# ── Test 1: all checks pass with valid setup ──
setup
RESULT=$(ANTHROPIC_API_KEY="sk-test" PATH="${TEST_BIN}:${PATH}" schedule_preflight_check cron "$TEST_REPO" 2>&1)
EXIT=$?
assert_eq "preflight passes with valid setup" "0" "$EXIT"
teardown

# ── Test 2: API key not resolvable fails ──
if [[ "$KEYCHAIN_AVAILABLE" -eq 1 ]]; then
  echo "  SKIP: API key resolves via Keychain — cannot test failure"
else
  setup
  if ANTHROPIC_API_KEY="" PATH="${TEST_BIN}:${PATH}" schedule_preflight_check cron "$TEST_REPO" 2>/dev/null; then
    assert_eq "preflight fails without resolvable API key" "1" "0"
  else
    assert_eq "preflight fails without resolvable API key" "1" "1"
  fi
  teardown
fi

# ── Test 3: claude not found fails ──
setup
rm "${TEST_BIN}/claude"
if ANTHROPIC_API_KEY="sk-test" PATH="${TEST_BIN}" schedule_preflight_check cron "$TEST_REPO" 2>/dev/null; then
  assert_eq "preflight fails without claude" "1" "0"
else
  assert_eq "preflight fails without claude" "1" "1"
fi
teardown

# ── Test 4: gh not found fails ──
setup
rm "${TEST_BIN}/gh"
if ANTHROPIC_API_KEY="sk-test" PATH="${TEST_BIN}" schedule_preflight_check cron "$TEST_REPO" 2>/dev/null; then
  assert_eq "preflight fails without gh" "1" "0"
else
  assert_eq "preflight fails without gh" "1" "1"
fi
teardown

# ── Test 5: git not found fails ──
setup
rm "${TEST_BIN}/git"
if ANTHROPIC_API_KEY="sk-test" PATH="${TEST_BIN}" schedule_preflight_check cron "$TEST_REPO" 2>/dev/null; then
  assert_eq "preflight fails without git" "1" "0"
else
  assert_eq "preflight fails without git" "1" "1"
fi
teardown

# ── Test 6: .claude/settings.json missing fails ──
setup
rm "${TEST_REPO}/.claude/settings.json"
if ANTHROPIC_API_KEY="sk-test" PATH="${TEST_BIN}:${PATH}" schedule_preflight_check cron "$TEST_REPO" 2>/dev/null; then
  assert_eq "preflight fails without settings.json" "1" "0"
else
  assert_eq "preflight fails without settings.json" "1" "1"
fi
teardown

# ── Test 7: multiple failures report all (no early exit) ──
setup
rm "${TEST_BIN}/claude"
rm "${TEST_REPO}/.claude/settings.json"
ERR=$(ANTHROPIC_API_KEY="" PATH="${TEST_BIN}" schedule_preflight_check cron "$TEST_REPO" 2>&1 || true)
FAIL_COUNT=$(echo "$ERR" | grep -c "FAIL" || true)
# claude + settings.json = at least 2 FAILs; +1 if API key also unresolvable
EXPECTED_MIN=$((2 + (1 - KEYCHAIN_AVAILABLE)))
if [[ "$FAIL_COUNT" -ge "$EXPECTED_MIN" ]]; then
  assert_eq "multiple failures all reported (>=${EXPECTED_MIN})" "1" "1"
else
  assert_eq "multiple failures all reported (expected >=${EXPECTED_MIN}, got ${FAIL_COUNT})" "fail" "fail"
fi
teardown

# ── Test 8: type=cron does not check atd ──
setup
ERR=$(ANTHROPIC_API_KEY="sk-test" PATH="${TEST_BIN}:${PATH}" schedule_preflight_check cron "$TEST_REPO" 2>&1)
if echo "$ERR" | grep -q "atd"; then
  assert_eq "cron type does not check atd" "no-atd" "has-atd"
else
  assert_eq "cron type does not check atd" "no-atd" "no-atd"
fi
teardown

# ── Test 9: type=at on Linux checks atd (skip on macOS) ──
if [[ "$(uname)" != "Darwin" ]]; then
  setup
  ERR=$(ANTHROPIC_API_KEY="sk-test" PATH="${TEST_BIN}:${PATH}" schedule_preflight_check at "$TEST_REPO" 2>&1 || true)
  assert_match "at type on Linux mentions atd" "atd" "$ERR"
  teardown
else
  echo "  SKIP: atd check test skipped on macOS"
fi

report_results
