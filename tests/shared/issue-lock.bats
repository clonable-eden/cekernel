#!/usr/bin/env bats
# issue-lock.bats — bats-core tests for scripts/shared/issue-lock.sh
#
# Covers session-token lock holders (ADR-0005 Amendment 1, ADR-0016
# Phase 1): under --bg delegation the lock holder is an opaque session
# token, not a PID. Staleness maps to `claude agents --json` state:
# busy|blocked = alive (locked), done|stopped|missing = stale, query
# failure = conservatively alive (never steal a lock on doubt).
#
# Numeric-PID holder behavior is covered by the legacy
# tests/shared/test-issue-lock.sh (pre-ADR-0017 harness).

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

TOKEN="aaaa1111-2222-4333-8444-555566667777"
REPO="/tmp/test-repo-token"
ISSUE=42

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export CEKERNEL_VAR_DIR="${BATS_TEST_TMPDIR}/var"
  mkdir -p "${CEKERNEL_VAR_DIR}/locks"
  mock_claude
  source "${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"
}

# Helper: create a lock held by an opaque session token
_lock_with_token() {
  local hash
  hash=$(issue_lock_repo_hash "$REPO")
  LOCK_DIR="${CEKERNEL_VAR_DIR}/locks/${hash}/${ISSUE}.lock"
  mkdir -p "$LOCK_DIR"
  echo "$TOKEN" > "${LOCK_DIR}/pid"
}

@test "acquire fails while the token holder session is busy" {
  _lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"
  run issue_lock_acquire "$REPO" "$ISSUE"
  assert_eq "acquire fails (locked)" "1" "$status"
}

@test "acquire fails while the token holder session is blocked" {
  _lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 blocked)]"
  run issue_lock_acquire "$REPO" "$ISSUE"
  assert_eq "acquire fails (locked)" "1" "$status"
}

@test "acquire steals the lock when the token holder session is done" {
  _lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 done)]"
  run issue_lock_acquire "$REPO" "$ISSUE"
  assert_eq "acquire succeeds (stale)" "0" "$status"
}

@test "acquire steals the lock when the token holder session is not listed" {
  _lock_with_token
  # empty agents queue → []
  run issue_lock_acquire "$REPO" "$ISSUE"
  assert_eq "acquire succeeds (stale)" "0" "$status"
}

@test "acquire fails when the agents query errors (conservative)" {
  _lock_with_token
  mock_bin claude 'exit 1'
  run issue_lock_acquire "$REPO" "$ISSUE"
  assert_eq "acquire fails (cannot verify → assume alive)" "1" "$status"
}

@test "check reports locked while the token holder session is busy" {
  _lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"
  run issue_lock_check "$REPO" "$ISSUE"
  assert_eq "check reports locked" "0" "$status"
}

@test "check reports stale when the token holder session is stopped" {
  _lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 stopped)]"
  run issue_lock_check "$REPO" "$ISSUE"
  assert_eq "check reports unlocked (stale)" "1" "$status"
}

@test "prefix-matches a short-ID token holder (degraded capture)" {
  local hash
  hash=$(issue_lock_repo_hash "$REPO")
  LOCK_DIR="${CEKERNEL_VAR_DIR}/locks/${hash}/${ISSUE}.lock"
  mkdir -p "$LOCK_DIR"
  echo "aaaa1111" > "${LOCK_DIR}/pid"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"
  run issue_lock_acquire "$REPO" "$ISSUE"
  assert_eq "acquire fails (short-ID holder alive)" "1" "$status"
}
