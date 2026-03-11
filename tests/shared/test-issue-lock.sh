#!/usr/bin/env bash
# test-issue-lock.sh — Tests for issue-lock.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCK_SCRIPT="${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"

echo "test: issue-lock"

# ── Setup ──
export CEKERNEL_VAR_DIR="$(mktemp -d)"
mkdir -p "${CEKERNEL_VAR_DIR}/locks"

source "$LOCK_SCRIPT"

REPO_A="/tmp/test-repo-alpha"
REPO_B="/tmp/test-repo-beta"
ISSUE=42

cleanup() {
  rm -rf "$CEKERNEL_VAR_DIR"
}
trap cleanup EXIT

# ── Test 1: issue_lock_acquire creates lock directory ──
issue_lock_acquire "$REPO_A" "$ISSUE"
HASH=$(issue_lock_repo_hash "$REPO_A")
LOCK_DIR="${CEKERNEL_VAR_DIR}/locks/${HASH}/${ISSUE}.lock"
assert_dir_exists "Lock directory created" "$LOCK_DIR"

# ── Test 2: PID file exists inside lock directory ──
assert_file_exists "PID file exists" "${LOCK_DIR}/pid"

# ── Test 3: PID value is current process ──
PID_VALUE=$(cat "${LOCK_DIR}/pid")
assert_eq "PID matches current process" "$$" "$PID_VALUE"

# ── Test 4: Duplicate acquire fails ──
EXIT_CODE=0
issue_lock_acquire "$REPO_A" "$ISSUE" 2>/dev/null || EXIT_CODE=$?
assert_eq "Duplicate acquire fails" "1" "$EXIT_CODE"

# ── Test 5: issue_lock_release removes lock ──
issue_lock_release "$REPO_A" "$ISSUE"
assert_not_exists "Lock directory removed after release" "$LOCK_DIR"

# ── Test 6: Re-acquire after release succeeds ──
EXIT_CODE=0
issue_lock_acquire "$REPO_A" "$ISSUE" || EXIT_CODE=$?
assert_eq "Re-acquire after release succeeds" "0" "$EXIT_CODE"
issue_lock_release "$REPO_A" "$ISSUE"

# ── Test 7: Stale lock detection (dead PID) ──
# Manually create a lock with a dead PID
HASH=$(issue_lock_repo_hash "$REPO_A")
LOCK_DIR="${CEKERNEL_VAR_DIR}/locks/${HASH}/${ISSUE}.lock"
mkdir -p "$LOCK_DIR"
echo "99999" > "${LOCK_DIR}/pid"
# Acquire should succeed by recovering the stale lock
EXIT_CODE=0
issue_lock_acquire "$REPO_A" "$ISSUE" || EXIT_CODE=$?
assert_eq "Stale lock recovered and acquired" "0" "$EXIT_CODE"
issue_lock_release "$REPO_A" "$ISSUE"

# ── Test 8: issue_lock_check returns 0 when locked, 1 when unlocked ──
issue_lock_acquire "$REPO_A" "$ISSUE"
EXIT_CODE=0
issue_lock_check "$REPO_A" "$ISSUE" || EXIT_CODE=$?
assert_eq "lock_check returns 0 when locked" "0" "$EXIT_CODE"
issue_lock_release "$REPO_A" "$ISSUE"
EXIT_CODE=0
issue_lock_check "$REPO_A" "$ISSUE" || EXIT_CODE=$?
assert_eq "lock_check returns 1 when unlocked" "1" "$EXIT_CODE"

# ── Test 9: Different repos produce different hashes ──
HASH_A=$(issue_lock_repo_hash "$REPO_A")
HASH_B=$(issue_lock_repo_hash "$REPO_B")
assert_eq "Different repos have different hashes" "1" "$([[ "$HASH_A" != "$HASH_B" ]] && echo 1 || echo 0)"

# ── Test 10: Same repo, different issues have independent locks ──
issue_lock_acquire "$REPO_A" 10
issue_lock_acquire "$REPO_A" 20
EXIT_CODE_10=0
issue_lock_check "$REPO_A" 10 || EXIT_CODE_10=$?
EXIT_CODE_20=0
issue_lock_check "$REPO_A" 20 || EXIT_CODE_20=$?
assert_eq "Issue 10 is locked" "0" "$EXIT_CODE_10"
assert_eq "Issue 20 is locked" "0" "$EXIT_CODE_20"
issue_lock_release "$REPO_A" 10
EXIT_CODE_10=0
issue_lock_check "$REPO_A" 10 || EXIT_CODE_10=$?
EXIT_CODE_20=0
issue_lock_check "$REPO_A" 20 || EXIT_CODE_20=$?
assert_eq "Issue 10 unlocked after release" "1" "$EXIT_CODE_10"
assert_eq "Issue 20 still locked" "0" "$EXIT_CODE_20"
issue_lock_release "$REPO_A" 20

# ── Test 11: issue_lock_update_pid updates PID in existing lock ──
issue_lock_acquire "$REPO_A" "$ISSUE"
HASH=$(issue_lock_repo_hash "$REPO_A")
LOCK_DIR="${CEKERNEL_VAR_DIR}/locks/${HASH}/${ISSUE}.lock"
OLD_PID=$(cat "${LOCK_DIR}/pid")
assert_eq "Initial PID is current process" "$$" "$OLD_PID"
issue_lock_update_pid "$REPO_A" "$ISSUE" "12345"
NEW_PID=$(cat "${LOCK_DIR}/pid")
assert_eq "PID updated to 12345" "12345" "$NEW_PID"
issue_lock_release "$REPO_A" "$ISSUE"

# ── Test 12: issue_lock_update_pid fails when no lock exists ──
EXIT_CODE=0
issue_lock_update_pid "$REPO_A" 99999 "12345" 2>/dev/null || EXIT_CODE=$?
assert_eq "update_pid fails without lock" "1" "$EXIT_CODE"

# ── Test 13: issue_lock_check sees updated PID as alive ──
issue_lock_acquire "$REPO_A" "$ISSUE"
# Update PID to current process (known alive)
issue_lock_update_pid "$REPO_A" "$ISSUE" "$$"
EXIT_CODE=0
issue_lock_check "$REPO_A" "$ISSUE" || EXIT_CODE=$?
assert_eq "lock_check sees updated live PID as locked" "0" "$EXIT_CODE"
# Update PID to a dead process
issue_lock_update_pid "$REPO_A" "$ISSUE" "99999"
EXIT_CODE=0
issue_lock_check "$REPO_A" "$ISSUE" || EXIT_CODE=$?
assert_eq "lock_check sees updated dead PID as stale" "1" "$EXIT_CODE"
issue_lock_release "$REPO_A" "$ISSUE"

report_results
