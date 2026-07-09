#!/usr/bin/env bats
# issue-lock.bats — bats-core tests for scripts/shared/issue-lock.sh
#
# Consolidates (ADR-0017 Decision 4, #552):
#   - test-issue-lock.sh                   (lock lifecycle behavior)
#   - test-issue-lock-load-env-fallback.sh (CEKERNEL_SCRIPTS path fallback)
# zsh-compat coverage lives in tests/shared/zsh-compat.bats.
#
# Also covers session-token lock holders (ADR-0005 Amendment 1, ADR-0016
# Phase 1, #546): under --bg delegation the lock holder is an opaque
# session token, not a PID. Staleness maps to `claude agents --json`
# state: busy|blocked = alive (locked), done|stopped|missing = stale,
# query failure = conservatively alive (never steal a lock on doubt).

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LOCK_SCRIPT="${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"

  # Per-test isolated lock root; neutral profile dirs keep load-env.sh
  # (sourced by issue-lock.sh) from reading real user/project profiles.
  export CEKERNEL_VAR_DIR="${BATS_TEST_TMPDIR}/var"
  mkdir -p "${CEKERNEL_VAR_DIR}/locks" "${BATS_TEST_TMPDIR}/neutral"
  export _CEKERNEL_PLUGIN_ENVS_DIR="${BATS_TEST_TMPDIR}/neutral"
  export _CEKERNEL_PROJECT_ENVS_DIR="${BATS_TEST_TMPDIR}/neutral"
  export _CEKERNEL_USER_ENVS_DIR="${BATS_TEST_TMPDIR}/neutral"

  REPO_A="/tmp/test-repo-alpha"
  REPO_B="/tmp/test-repo-beta"
  ISSUE=42

  source "$LOCK_SCRIPT"
}

lock_dir_for() {
  local repo="$1" issue="$2"
  echo "${CEKERNEL_VAR_DIR}/locks/$(issue_lock_repo_hash "$repo")/${issue}.lock"
}

# ── Lock lifecycle ──

@test "issue_lock_acquire creates lock directory with PID file" {
  issue_lock_acquire "$REPO_A" "$ISSUE"
  local lock_dir
  lock_dir=$(lock_dir_for "$REPO_A" "$ISSUE")
  assert_dir_exists "Lock directory created" "$lock_dir"
  assert_file_exists "PID file exists" "${lock_dir}/pid"
  assert_eq "PID matches current process" "$$" "$(cat "${lock_dir}/pid")"
}

@test "duplicate acquire fails" {
  issue_lock_acquire "$REPO_A" "$ISSUE"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "Duplicate acquire fails" "1" "$status"
}

@test "issue_lock_release removes lock" {
  issue_lock_acquire "$REPO_A" "$ISSUE"
  issue_lock_release "$REPO_A" "$ISSUE"
  assert_not_exists "Lock directory removed after release" \
    "$(lock_dir_for "$REPO_A" "$ISSUE")"
}

@test "re-acquire after release succeeds" {
  issue_lock_acquire "$REPO_A" "$ISSUE"
  issue_lock_release "$REPO_A" "$ISSUE"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "Re-acquire after release succeeds" "0" "$status"
}

@test "stale lock (dead PID) is recovered on acquire" {
  local lock_dir
  lock_dir=$(lock_dir_for "$REPO_A" "$ISSUE")
  mkdir -p "$lock_dir"
  echo "99999" > "${lock_dir}/pid"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "Stale lock recovered and acquired" "0" "$status"
}

@test "issue_lock_check returns 0 when locked, 1 when unlocked" {
  issue_lock_acquire "$REPO_A" "$ISSUE"
  run issue_lock_check "$REPO_A" "$ISSUE"
  assert_eq "lock_check returns 0 when locked" "0" "$status"
  issue_lock_release "$REPO_A" "$ISSUE"
  run issue_lock_check "$REPO_A" "$ISSUE"
  assert_eq "lock_check returns 1 when unlocked" "1" "$status"
}

@test "different repos produce different hashes" {
  local hash_a hash_b
  hash_a=$(issue_lock_repo_hash "$REPO_A")
  hash_b=$(issue_lock_repo_hash "$REPO_B")
  assert_eq "Different repos have different hashes" "1" \
    "$([[ "$hash_a" != "$hash_b" ]] && echo 1 || echo 0)"
}

@test "same repo, different issues have independent locks" {
  issue_lock_acquire "$REPO_A" 10
  issue_lock_acquire "$REPO_A" 20
  run issue_lock_check "$REPO_A" 10
  assert_eq "Issue 10 is locked" "0" "$status"
  run issue_lock_check "$REPO_A" 20
  assert_eq "Issue 20 is locked" "0" "$status"

  issue_lock_release "$REPO_A" 10
  run issue_lock_check "$REPO_A" 10
  assert_eq "Issue 10 unlocked after release" "1" "$status"
  run issue_lock_check "$REPO_A" 20
  assert_eq "Issue 20 still locked" "0" "$status"
}

# ── PID update ──

@test "issue_lock_update_pid updates PID in existing lock" {
  issue_lock_acquire "$REPO_A" "$ISSUE"
  local lock_dir
  lock_dir=$(lock_dir_for "$REPO_A" "$ISSUE")
  assert_eq "Initial PID is current process" "$$" "$(cat "${lock_dir}/pid")"
  issue_lock_update_pid "$REPO_A" "$ISSUE" "12345"
  assert_eq "PID updated to 12345" "12345" "$(cat "${lock_dir}/pid")"
}

@test "issue_lock_update_pid fails when no lock exists" {
  run issue_lock_update_pid "$REPO_A" 99999 "12345"
  assert_eq "update_pid fails without lock" "1" "$status"
}

@test "issue_lock_check follows updated PID liveness" {
  issue_lock_acquire "$REPO_A" "$ISSUE"
  # Update PID to current process (known alive)
  issue_lock_update_pid "$REPO_A" "$ISSUE" "$$"
  run issue_lock_check "$REPO_A" "$ISSUE"
  assert_eq "lock_check sees updated live PID as locked" "0" "$status"
  # Update PID to a dead process
  issue_lock_update_pid "$REPO_A" "$ISSUE" "99999"
  run issue_lock_check "$REPO_A" "$ISSUE"
  assert_eq "lock_check sees updated dead PID as stale" "1" "$status"
}

# ── load-env.sh path resolution fallback (plugin mode zsh eval context) ──
# issue-lock.sh must find load-env.sh via CEKERNEL_SCRIPTS when BASH_SOURCE[0]
# does not resolve to the real scripts/shared directory.

@test "CEKERNEL_SCRIPTS fallback resolves load-env.sh" {
  # Copy issue-lock.sh to a dir without load-env.sh so BASH_SOURCE resolution
  # fails and the CEKERNEL_SCRIPTS fallback must kick in.
  local fake_dir="${BATS_TEST_TMPDIR}/fake"
  mkdir -p "$fake_dir"
  cp "$LOCK_SCRIPT" "${fake_dir}/issue-lock.sh"
  run bash -c "export CEKERNEL_SCRIPTS='${CEKERNEL_DIR}/scripts'; \
    source '${fake_dir}/issue-lock.sh'; \
    issue_lock_repo_hash '/tmp/test-repo' >/dev/null"
  assert_eq "CEKERNEL_SCRIPTS fallback resolves load-env.sh" "0" "$status"
}

@test "normal BASH_SOURCE resolution works without CEKERNEL_SCRIPTS" {
  run env -u CEKERNEL_SCRIPTS bash -c "source '${LOCK_SCRIPT}'; \
    issue_lock_repo_hash '/tmp/test-repo' >/dev/null"
  assert_eq "Normal BASH_SOURCE resolution works without CEKERNEL_SCRIPTS" \
    "0" "$status"
}

@test "lock functions work via CEKERNEL_SCRIPTS fallback" {
  local fake_dir="${BATS_TEST_TMPDIR}/fake"
  mkdir -p "$fake_dir"
  cp "$LOCK_SCRIPT" "${fake_dir}/issue-lock.sh"
  run bash -c "export CEKERNEL_SCRIPTS='${CEKERNEL_DIR}/scripts'; \
    source '${fake_dir}/issue-lock.sh'; \
    issue_lock_acquire '/tmp/test-fallback-repo' 999 && \
    issue_lock_check '/tmp/test-fallback-repo' 999 && \
    issue_lock_release '/tmp/test-fallback-repo' 999"
  assert_eq "Lock functions work via CEKERNEL_SCRIPTS fallback" "0" "$status"
}

# ── Session-token lock holders (ADR-0005 Amendment 1, #546) ──

TOKEN="aaaa1111-2222-4333-8444-555566667777"

# Create a lock held by an opaque session token
lock_with_token() {
  local token="${1:-$TOKEN}"
  local lock_dir
  lock_dir=$(lock_dir_for "$REPO_A" "$ISSUE")
  mkdir -p "$lock_dir"
  echo "$token" > "${lock_dir}/pid"
}

@test "acquire fails while the token holder session is busy" {
  mock_claude
  lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire fails (locked)" "1" "$status"
}

@test "acquire fails while the token holder session is blocked" {
  mock_claude
  lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 blocked)]"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire fails (locked)" "1" "$status"
}

@test "acquire steals the lock when the token holder session is done" {
  mock_claude
  lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 done)]"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire succeeds (stale)" "0" "$status"
}

@test "acquire steals the lock when the token holder session is not listed" {
  mock_claude
  lock_with_token
  # empty agents queue → []
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire succeeds (stale)" "0" "$status"
}

@test "acquire fails when the agents query errors (conservative)" {
  lock_with_token
  mock_bin claude 'exit 1'
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire fails (cannot verify → assume alive)" "1" "$status"
}

@test "acquire fails on an unknown (status, state) pair (conservative)" {
  # ADR-0018 degradation policy: unknown-value is schema drift, not
  # evidence of death — never steal a lock on doubt.
  mock_claude
  lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$TOKEN" background /tmp/wt 1700000000000 running active)]"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire fails (unknown-value → assume alive)" "1" "$status"
}

@test "check reports locked while the token holder session is busy" {
  mock_claude
  lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"
  run issue_lock_check "$REPO_A" "$ISSUE"
  assert_eq "check reports locked" "0" "$status"
}

@test "check reports stale when the token holder session is stopped" {
  mock_claude
  lock_with_token
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 stopped)]"
  run issue_lock_check "$REPO_A" "$ISSUE"
  assert_eq "check reports unlocked (stale)" "1" "$status"
}

@test "acquire steals the lock when the holder file is empty (corrupt write)" {
  # An empty holder falls into the non-numeric token path where
  # startswith("") matches EVERY session — an unrelated busy session
  # must not keep a corrupt lock alive (PR #572 follow-up, #573).
  mock_claude
  local lock_dir
  lock_dir=$(lock_dir_for "$REPO_A" "$ISSUE")
  mkdir -p "$lock_dir"
  : > "${lock_dir}/pid"   # empty pid file
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire succeeds (empty holder is stale)" "0" "$status"
}

@test "prefix-matches a short-ID token holder (degraded capture)" {
  mock_claude
  lock_with_token "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"
  run issue_lock_acquire "$REPO_A" "$ISSUE"
  assert_eq "acquire fails (short-ID holder alive)" "1" "$status"
}
