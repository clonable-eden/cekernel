#!/usr/bin/env bats
# notify-complete.bats — bats-core tests for scripts/process/notify-complete.sh
#
# ADR-0020 Phase 3: FIFO write path removed. notify-complete.sh now writes
# state + lifecycle log + issue-lock release unconditionally (no FIFO).
#
# Consolidates (ADR-0017 Decision 4):
#   tests/process/test-ipc-lifecycle.sh        — state write path
#   tests/process/test-notify-complete-no-fifo.sh — state-first ordering
#   tests/process/test-notify-complete-lock.sh — issue-lock retention by result

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  NOTIFY_SCRIPT="${CEKERNEL_DIR}/scripts/process/notify-complete.sh"

  # Isolate all runtime state (IPC dir + issue locks) per test
  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"

  source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"
  source "${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR"
}

# Create a temp git repo (physical path, so it matches
# `git rev-parse --show-toplevel` on macOS /var → /private/var symlinks).
make_temp_repo() {
  local repo
  repo=$(mktemp -d)
  repo=$(cd "$repo" && pwd -P)
  git -C "$repo" init -q
  echo "$repo"
}

# Acquire the issue lock, run notify-complete.sh from inside a temp repo,
# and return issue_lock_check's exit code via $LOCK_CHECK (0 = still locked,
# 1 = released).
run_lock_case() {
  local issue="$1" result="$2" detail="$3"
  TEMP_REPO=$(make_temp_repo)

  issue_lock_acquire "$TEMP_REPO" "$issue"

  (cd "$TEMP_REPO" && bash "$NOTIFY_SCRIPT" "$issue" "$result" "$detail") 2>/dev/null || true

  LOCK_CHECK=0
  issue_lock_check "$TEMP_REPO" "$issue" || LOCK_CHECK=$?
  rm -rf "$TEMP_REPO"
}

# ── State write path ──

@test "writes TERMINATED state with result and detail" {
  run bash "$NOTIFY_SCRIPT" 42 merged 99
  assert_eq "notify-complete exits 0" "0" "$status"

  local state_json
  state_json=$(worker_state_read 42)
  assert_eq "state is TERMINATED" "TERMINATED" "$(echo "$state_json" | jq -r '.state')"
  assert_eq "detail carries result:detail" "merged:99" "$(echo "$state_json" | jq -r '.detail')"
}

# ── Lifecycle log ──

@test "lifecycle event is logged unconditionally" {
  bash "$NOTIFY_SCRIPT" 50 merged 99 2>/dev/null

  local log_file="${CEKERNEL_IPC_DIR}/logs/worker-50.log"
  assert_file_exists "log file exists" "$log_file"
  assert_match "COMPLETE logged" "COMPLETE" "$(cat "$log_file")"
  assert_match "result logged" "result=merged" "$(cat "$log_file")"
}

# ── ADR-0020 Phase 1a: state payload carries result AND detail ──

@test "state payload includes result and detail separated by colon" {
  bash "$NOTIFY_SCRIPT" 80 ci-passed 42 2>/dev/null

  local state_json
  state_json=$(worker_state_read 80)
  assert_eq "state is TERMINATED" "TERMINATED" "$(echo "$state_json" | jq -r '.state')"
  assert_eq "detail carries result:detail" "ci-passed:42" "$(echo "$state_json" | jq -r '.detail')"
}

@test "state payload with empty detail writes result only" {
  bash "$NOTIFY_SCRIPT" 81 cancelled 2>/dev/null

  local state_json
  state_json=$(worker_state_read 81)
  assert_eq "state is TERMINATED" "TERMINATED" "$(echo "$state_json" | jq -r '.state')"
  # Empty detail: result is still the first field, no trailing colon content
  assert_eq "detail carries result with empty suffix" "cancelled:" "$(echo "$state_json" | jq -r '.detail')"
}

# ── Issue-lock retention by result ──
# Lock retention policy:
#   ci-passed, changes-requested, approved → Orchestrator-managed transitions, lock retained
#   merged, failed, cancelled → terminal lifecycle events, lock released

@test "ci-passed retains issue lock" {
  run_lock_case 70 ci-passed 42
  assert_eq "ci-passed retains lock" "0" "$LOCK_CHECK"
}

@test "changes-requested retains issue lock" {
  run_lock_case 71 changes-requested 55
  assert_eq "changes-requested retains lock" "0" "$LOCK_CHECK"
}

@test "approved retains issue lock" {
  run_lock_case 72 approved 55
  assert_eq "approved retains lock" "0" "$LOCK_CHECK"
}

@test "merged releases issue lock" {
  run_lock_case 73 merged 99
  assert_eq "merged releases lock" "1" "$LOCK_CHECK"
}

@test "failed releases issue lock" {
  run_lock_case 74 failed "CI failed"
  assert_eq "failed releases lock" "1" "$LOCK_CHECK"
}

@test "cancelled releases issue lock" {
  run_lock_case 75 cancelled "TERM signal"
  assert_eq "cancelled releases lock" "1" "$LOCK_CHECK"
}
