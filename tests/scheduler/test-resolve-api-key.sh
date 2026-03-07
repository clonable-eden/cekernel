#!/usr/bin/env bash
# test-resolve-api-key.sh — Tests for scheduler/resolve-api-key.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESOLVE_SCRIPT="${CEKERNEL_DIR}/scripts/scheduler/resolve-api-key.sh"

echo "test: scheduler/resolve-api-key.sh"

# ── Test 1: ANTHROPIC_API_KEY set — returns it ──
RESULT=$(ANTHROPIC_API_KEY="sk-test-key-123" bash "$RESOLVE_SCRIPT")
assert_eq "returns ANTHROPIC_API_KEY when set" "sk-test-key-123" "$RESULT"

# ── Test 2: ANTHROPIC_API_KEY empty — treated as unset ──
if RESULT=$(ANTHROPIC_API_KEY="" bash "$RESOLVE_SCRIPT" 2>/dev/null); then
  # On macOS, Keychain might actually resolve — check if we got something
  if [[ -n "$RESULT" ]]; then
    echo "  SKIP: Keychain resolved a key (macOS with valid Keychain entry)"
  else
    assert_eq "empty ANTHROPIC_API_KEY fails" "1" "0"
  fi
else
  assert_eq "empty ANTHROPIC_API_KEY fails on non-Darwin or no Keychain" "1" "1"
fi

# ── Test 3: unset ANTHROPIC_API_KEY on non-Darwin — exit 1 ──
if [[ "$(uname)" != "Darwin" ]]; then
  if RESULT=$(unset ANTHROPIC_API_KEY; bash "$RESOLVE_SCRIPT" 2>/dev/null); then
    assert_eq "unset key on non-Darwin exits 1" "1" "0"
  else
    assert_eq "unset key on non-Darwin exits 1" "1" "1"
  fi
else
  echo "  SKIP: Keychain fallback test skipped on macOS"
fi

# ── Test 4: script outputs to stderr on failure ──
ERR=$(ANTHROPIC_API_KEY="" bash "$RESOLVE_SCRIPT" 2>&1 >/dev/null || true)
if [[ "$(uname)" == "Darwin" ]]; then
  # May succeed via Keychain — only check if it actually failed
  if ! ANTHROPIC_API_KEY="" bash "$RESOLVE_SCRIPT" >/dev/null 2>&1; then
    assert_match "error message on failure" "ANTHROPIC_API_KEY" "$ERR"
  else
    echo "  SKIP: Keychain resolved, no error to check"
  fi
else
  assert_match "error message on failure" "ANTHROPIC_API_KEY" "$ERR"
fi

report_results
