#!/usr/bin/env bats
# notify-complete.bats — bats-core tests for scripts/process/notify-complete.sh
#
# Consolidates (ADR-0017 Decision 4):
#   tests/process/test-ipc-lifecycle.sh        — FIFO write path (JSON message)
#   tests/process/test-notify-complete-no-fifo.sh — state-first ordering when FIFO missing
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

# Create FIFO for the issue and start a background reader writing to $2.
# Closes FD 3 so bats does not block on the background child.
start_fifo_reader() {
  local issue="$1" out="${2:-/dev/null}"
  mkfifo "${CEKERNEL_IPC_DIR}/worker-${issue}"
  cat "${CEKERNEL_IPC_DIR}/worker-${issue}" > "$out" 3>&- &
  READER_PID=$!
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

# Acquire the issue lock, run notify-complete.sh from inside a temp repo with
# a FIFO reader attached, and return issue_lock_check's exit code via
# $LOCK_CHECK (0 = still locked, 1 = released).
run_lock_case() {
  local issue="$1" result="$2" detail="$3"
  TEMP_REPO=$(make_temp_repo)

  issue_lock_acquire "$TEMP_REPO" "$issue"
  start_fifo_reader "$issue"

  (cd "$TEMP_REPO" && bash "$NOTIFY_SCRIPT" "$issue" "$result" "$detail") 2>/dev/null || true
  wait "$READER_PID" 2>/dev/null || true

  LOCK_CHECK=0
  issue_lock_check "$TEMP_REPO" "$issue" || LOCK_CHECK=$?
  rm -rf "$TEMP_REPO"
}

# ── FIFO write path (from test-ipc-lifecycle.sh) ──

@test "writes JSON message with issue, result, detail, timestamp to FIFO" {
  local result_file="${CEKERNEL_VAR_DIR}/fifo-result"
  start_fifo_reader 42 "$result_file"

  run bash "$NOTIFY_SCRIPT" 42 merged 99
  assert_eq "notify-complete exits 0" "0" "$status"

  wait "$READER_PID"
  local message
  message=$(cat "$result_file")
  assert_match "message contains issue number" '"issue":42' "$message"
  assert_match "message contains result" '"result":"merged"' "$message"
  assert_match "message contains detail" '"detail":"99"' "$message"
  assert_match "message contains timestamp" '"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$message"
}

# ── Missing FIFO: state-first ordering (from test-notify-complete-no-fifo.sh) ──

@test "missing FIFO: exits 0 and warns on stderr" {
  run bash "$NOTIFY_SCRIPT" 50 merged 99
  assert_eq "exits 0 when FIFO missing" "0" "$status"
  assert_match "warning about FIFO missing" "FIFO not found" "$output"
}

@test "missing FIFO: state is still written as TERMINATED" {
  bash "$NOTIFY_SCRIPT" 50 merged 99 2>/dev/null

  local state_json
  state_json=$(worker_state_read 50)
  assert_eq "state is TERMINATED" "TERMINATED" "$(echo "$state_json" | jq -r '.state')"
  assert_eq "detail carries result:detail" "merged:99" "$(echo "$state_json" | jq -r '.detail')"
}

# ── ADR-0020 Phase 1a: state payload carries result AND detail ──

@test "state payload includes result and detail separated by colon" {
  start_fifo_reader 80
  bash "$NOTIFY_SCRIPT" 80 ci-passed 42 2>/dev/null
  wait "$READER_PID" 2>/dev/null || true

  local state_json
  state_json=$(worker_state_read 80)
  assert_eq "state is TERMINATED" "TERMINATED" "$(echo "$state_json" | jq -r '.state')"
  assert_eq "detail carries result:detail" "ci-passed:42" "$(echo "$state_json" | jq -r '.detail')"
}

@test "state payload with empty detail writes result only" {
  start_fifo_reader 81
  bash "$NOTIFY_SCRIPT" 81 cancelled 2>/dev/null
  wait "$READER_PID" 2>/dev/null || true

  local state_json
  state_json=$(worker_state_read 81)
  assert_eq "state is TERMINATED" "TERMINATED" "$(echo "$state_json" | jq -r '.state')"
  # Empty detail: result is still the first field, no trailing colon content
  assert_eq "detail carries result with empty suffix" "cancelled:" "$(echo "$state_json" | jq -r '.detail')"
}

@test "missing FIFO: FIFO_MISSING event is logged" {
  bash "$NOTIFY_SCRIPT" 50 merged 99 2>/dev/null

  local log_file="${CEKERNEL_IPC_DIR}/logs/worker-50.log"
  assert_file_exists "log file exists" "$log_file"
  assert_match "FIFO_MISSING logged" "FIFO_MISSING" "$(cat "$log_file")"
}

# ── Issue-lock retention by result (from test-notify-complete-lock.sh) ──
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
