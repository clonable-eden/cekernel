#!/usr/bin/env bats
# wait-ci.bats — Tests for scripts/process/wait-ci.sh
#
# wait-ci.sh is a foreground blocking CI wait primitive for Workers.
# It wraps `gh pr checks --watch` with chunk timeout control to avoid
# Bash tool's 600s hard limit, following watch.sh's chunk pattern (#630).
#
# Contract:
#   - Runs `gh pr checks <pr> --watch` in foreground
#   - Self-limits to CEKERNEL_CI_CHUNK_TIMEOUT (default: 540s)
#   - Returns JSON: {"result":"passed|failed|watching", ...}
#   - Exit 0 for all results (caller inspects JSON)

load '../helpers/assertions'
load '../helpers/session'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WAIT_CI_SCRIPT="${CEKERNEL_DIR}/scripts/process/wait-ci.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"

  export CEKERNEL_CI_CHUNK_TIMEOUT=5
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

# ── Usage error ──

@test "wait-ci exits 1 without arguments" {
  run bash "$WAIT_CI_SCRIPT"
  assert_eq "exits 1" "1" "$status"
}

# ── All checks passed ──

@test "wait-ci reports passed when gh pr checks --watch exits 0" {
  mock_bin gh 'echo "All checks were successful"; exit 0'

  run bash "$WAIT_CI_SCRIPT" 123
  assert_eq "exits 0" "0" "$status"
  assert_match "result is passed" '"result":"passed"' "$output"
  assert_match "pr number" '"pr":123' "$output"
}

# ── Checks failed ──

@test "wait-ci reports failed when gh pr checks --watch exits non-zero" {
  mock_bin gh 'echo "Some checks were not successful"; exit 1'

  run bash "$WAIT_CI_SCRIPT" 456
  assert_eq "exits 0" "0" "$status"
  assert_match "result is failed" '"result":"failed"' "$output"
  assert_match "pr number" '"pr":456' "$output"
}

# ── Chunk timeout (watching sentinel) ──

@test "wait-ci returns watching when chunk timeout expires" {
  # gh pr checks --watch that never exits (simulated with sleep)
  mock_bin gh 'sleep 60'
  export CEKERNEL_CI_CHUNK_TIMEOUT=2

  run bash "$WAIT_CI_SCRIPT" 789
  assert_eq "exits 0" "0" "$status"
  assert_match "result is watching" '"result":"watching"' "$output"
  assert_match "pr number" '"pr":789' "$output"
}

# ── gh receives correct arguments ──

@test "wait-ci passes correct arguments to gh pr checks" {
  mock_bin gh '
    echo "$@" > "${BATS_TEST_TMPDIR}/gh-args.log"
    echo "All checks were successful"
    exit 0
  '

  run bash "$WAIT_CI_SCRIPT" 42
  local args
  args=$(cat "${BATS_TEST_TMPDIR}/gh-args.log")
  assert_match "pr checks with --watch" "pr checks 42 --watch" "$args"
}
