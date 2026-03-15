#!/usr/bin/env bash
# test-issue-lock-load-env-fallback.sh — Tests for issue-lock.sh load-env.sh path resolution fallback
#
# Verifies that issue-lock.sh can find load-env.sh even when BASH_SOURCE[0]
# does not resolve to the correct directory (e.g., plugin mode zsh eval context).
# The fallback uses CEKERNEL_SCRIPTS environment variable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCK_SCRIPT="${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"

echo "test: issue-lock load-env fallback"

# ── Setup ──
export CEKERNEL_VAR_DIR="$(mktemp -d)"
mkdir -p "${CEKERNEL_VAR_DIR}/locks"

cleanup() {
  rm -rf "$CEKERNEL_VAR_DIR"
}
trap cleanup EXIT

# ── Test 1: CEKERNEL_SCRIPTS fallback resolves load-env.sh ──
# Simulate plugin mode by setting CEKERNEL_SCRIPTS and sourcing from a directory
# where load-env.sh does NOT exist alongside issue-lock.sh.
# We create a symlink to issue-lock.sh in a temp directory (no load-env.sh there),
# then source it. With the fallback, it should find load-env.sh via CEKERNEL_SCRIPTS.
FAKE_DIR="$(mktemp -d)"
cp "$LOCK_SCRIPT" "${FAKE_DIR}/issue-lock.sh"
# No load-env.sh in FAKE_DIR — BASH_SOURCE[0] resolves to FAKE_DIR
export CEKERNEL_SCRIPTS="${CEKERNEL_DIR}/scripts"

EXIT_CODE=0
(
  source "${FAKE_DIR}/issue-lock.sh"
  # Verify functions are available
  issue_lock_repo_hash "/tmp/test-repo" >/dev/null
) || EXIT_CODE=$?
assert_eq "CEKERNEL_SCRIPTS fallback resolves load-env.sh" "0" "$EXIT_CODE"
rm -rf "$FAKE_DIR"

# ── Test 2: Normal BASH_SOURCE resolution still works (no CEKERNEL_SCRIPTS) ──
unset CEKERNEL_SCRIPTS
EXIT_CODE=0
(
  source "$LOCK_SCRIPT"
  issue_lock_repo_hash "/tmp/test-repo" >/dev/null
) || EXIT_CODE=$?
assert_eq "Normal BASH_SOURCE resolution works without CEKERNEL_SCRIPTS" "0" "$EXIT_CODE"

# ── Test 3: Lock functions work correctly via CEKERNEL_SCRIPTS fallback ──
export CEKERNEL_SCRIPTS="${CEKERNEL_DIR}/scripts"
FAKE_DIR="$(mktemp -d)"
cp "$LOCK_SCRIPT" "${FAKE_DIR}/issue-lock.sh"

EXIT_CODE=0
(
  source "${FAKE_DIR}/issue-lock.sh"
  REPO="/tmp/test-fallback-repo"
  issue_lock_acquire "$REPO" 999
  issue_lock_check "$REPO" 999
  issue_lock_release "$REPO" 999
) || EXIT_CODE=$?
assert_eq "Lock functions work via CEKERNEL_SCRIPTS fallback" "0" "$EXIT_CODE"
rm -rf "$FAKE_DIR"

report_results
