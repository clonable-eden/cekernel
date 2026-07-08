#!/usr/bin/env bats
# watch.bats — v2 contract tests for scripts/orchestrator/watch.sh
#
# Under --bg delegation (ADR-0016 Phase 1) watch.sh supervises headless
# Workers via the backend status (`claude agents --json` state):
#   - session gone / terminal state without TERMINATED → crashed
#   - blocked (permission-dialog stall) → surfaced as a distinct result
#   - busy → keep waiting (no false crash)
# Replaces the PID-liveness tests test-watch-crash-detection.sh and
# test-watch-env-backend.sh (deleted with the -p spawn path, ADR-0017 §3).

load '../helpers/assertions'
load '../helpers/session'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

TOKEN="aaaa1111-2222-4333-8444-555566667777"

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WATCH_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/watch.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"

  mock_claude
  export CEKERNEL_BACKEND=headless
  export CEKERNEL_POLL_INTERVAL=1
  export CEKERNEL_WORKER_TIMEOUT=10
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "watch reports crashed when the session is no longer listed" {
  worker_state_write 40 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-40.worker"
  # empty agents queue → [] → session missing

  run bash "$WATCH_SCRIPT" 40
  assert_eq "watch exits non-zero" "1" "$status"
  assert_match "result is crashed" '"result":"crashed"' "$output"
  assert_match "WORKER_CRASH logged" "WORKER_CRASH" \
    "$(cat "${CEKERNEL_IPC_DIR}/logs/worker-40.log")"
}

@test "watch reports crashed when the session is done without TERMINATED state" {
  worker_state_write 41 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-41.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 done)]"

  run bash "$WATCH_SCRIPT" 41
  assert_eq "watch exits non-zero" "1" "$status"
  assert_match "result is crashed" '"result":"crashed"' "$output"
}

@test "watch surfaces a blocked session as a distinct result" {
  worker_state_write 42 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-42.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 blocked)]"

  run bash "$WATCH_SCRIPT" 42
  assert_eq "watch exits non-zero" "1" "$status"
  assert_match "result is blocked" '"result":"blocked"' "$output"
  assert_match "WORKER_BLOCKED logged" "WORKER_BLOCKED" \
    "$(cat "${CEKERNEL_IPC_DIR}/logs/worker-42.log")"
}

@test "watch does not false-crash a busy session (state fallback completes)" {
  worker_state_write 182 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-182.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"

  local out="${BATS_TEST_TMPDIR}/watch-out.json"
  bash "$WATCH_SCRIPT" 182 > "$out" 2>/dev/null &
  local watch_pid=$!
  sleep 2
  worker_state_write 182 TERMINATED "merged:99"
  wait "$watch_pid"

  local result_json
  result_json=$(cat "$out")
  assert_match "result is merged" '"result":"merged"' "$result_json"
  assert_match "detail is 99" '"detail":"99"' "$result_json"
}

# ── ADR-0020 Phase 1a: build_result_from_state splits result and detail ──

@test "state fallback splits result and detail from state payload" {
  worker_state_write 620 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-620.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"

  local out="${BATS_TEST_TMPDIR}/watch-out.json"
  bash "$WATCH_SCRIPT" 620 > "$out" 2>/dev/null &
  local watch_pid=$!
  sleep 2
  worker_state_write 620 TERMINATED "ci-passed:42"
  wait "$watch_pid"

  local result_json
  result_json=$(cat "$out")
  assert_match "result is ci-passed" '"result":"ci-passed"' "$result_json"
  assert_match "detail is PR number" '"detail":"42"' "$result_json"
}

@test "state fallback handles detail with colons (backward compat)" {
  worker_state_write 621 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-621.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"

  local out="${BATS_TEST_TMPDIR}/watch-out.json"
  bash "$WATCH_SCRIPT" 621 > "$out" 2>/dev/null &
  local watch_pid=$!
  sleep 2
  worker_state_write 621 TERMINATED "failed:CI failed: 3 times"
  wait "$watch_pid"

  local result_json
  result_json=$(cat "$out")
  assert_match "result is failed" '"result":"failed"' "$result_json"
  assert_match "detail preserves colons" '"detail":"CI failed: 3 times"' "$result_json"
}

@test "state fallback handles old format without detail (backward compat)" {
  worker_state_write 622 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-622.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"

  local out="${BATS_TEST_TMPDIR}/watch-out.json"
  bash "$WATCH_SCRIPT" 622 > "$out" 2>/dev/null &
  local watch_pid=$!
  sleep 2
  # Old format: detail is just the result, no colon separator
  worker_state_write 622 TERMINATED "ci-passed"
  wait "$watch_pid"

  local result_json
  result_json=$(cat "$out")
  assert_match "result is ci-passed" '"result":"ci-passed"' "$result_json"
  assert_match "detail is empty for old format" '"detail":""' "$result_json"
}

@test "watch does not false-crash on a transient agents query failure" {
  # `claude agents --json` failing (daemon restarting) is NOT evidence
  # the session died — watch must keep polling instead of reporting a
  # crash (PR #572 follow-up, #573). Completion then arrives via the
  # state-file fallback.
  worker_state_write 573 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-573.worker"
  mock_bin claude 'exit 1'

  local out="${BATS_TEST_TMPDIR}/watch-out.json"
  bash "$WATCH_SCRIPT" 573 > "$out" 2>/dev/null &
  local watch_pid=$!
  sleep 2
  worker_state_write 573 TERMINATED "merged:#999"
  wait "$watch_pid"

  local result_json
  result_json=$(cat "$out")
  assert_match "result is merged" '"result":"merged"' "$result_json"
  assert_match "detail is #999" '"detail":"#999"' "$result_json"
}

@test "watch escalates after repeated consecutive agents query failures (ADR-0018)" {
  # Degradation policy: query-failed is retried, but a PERSISTENT failure
  # must escalate to the caller instead of silently polling to the
  # generic timeout — the detail warns the worker may still be running.
  worker_state_write 593 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-593.worker"
  mock_bin claude 'exit 1'
  export CEKERNEL_WATCH_QUERY_RETRY_MAX=2

  run bash "$WATCH_SCRIPT" 593
  assert_eq "watch exits non-zero" "1" "$status"
  assert_match "result is error" '"result":"error"' "$output"
  assert_match "detail names the query failure" "query" "$output"
  assert_match "detail warns the worker may still be running" \
    "may still be running" "$output"
}

@test "watch retries an unknown (status, state) pair instead of crash-flagging (ADR-0018)" {
  # Schema drift (unknown-value) is not evidence of death — watch keeps
  # polling and completion arrives via the state-file fallback.
  worker_state_write 594 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-594.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$TOKEN" background /tmp/wt 1700000000000 idle working)]"
  export CEKERNEL_WATCH_QUERY_RETRY_MAX=10

  local out="${BATS_TEST_TMPDIR}/watch-out.json"
  bash "$WATCH_SCRIPT" 594 > "$out" 2>/dev/null &
  local watch_pid=$!
  sleep 2
  worker_state_write 594 TERMINATED "merged:#999"
  wait "$watch_pid"

  local result_json
  result_json=$(cat "$out")
  assert_match "result is merged" '"result":"merged"' "$result_json"
  assert_match "detail is #999" '"detail":"#999"' "$result_json"
}

@test "watch resolves the headless backend from the env profile (#182 regression)" {
  worker_state_write 183 RUNNING "phase1:implement"
  echo "$TOKEN" > "${CEKERNEL_IPC_DIR}/handle-183.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$TOKEN" background /tmp/wt 1700000000000 busy)]"

  # Backend comes from the env profile, NOT from CEKERNEL_BACKEND
  local env_dir="${BATS_TEST_TMPDIR}/envs"
  mkdir -p "$env_dir"
  echo "CEKERNEL_BACKEND=headless" > "${env_dir}/test-headless.env"
  export CEKERNEL_ENV=test-headless
  export _CEKERNEL_PLUGIN_ENVS_DIR="$env_dir"
  unset CEKERNEL_BACKEND

  local out="${BATS_TEST_TMPDIR}/watch-out.json"
  bash "$WATCH_SCRIPT" 183 > "$out" 2>/dev/null &
  local watch_pid=$!
  sleep 2
  worker_state_write 183 TERMINATED "merged:#999"
  wait "$watch_pid"

  local result_json
  result_json=$(cat "$out")
  assert_match "no false crash — result is merged" '"result":"merged"' "$result_json"
  assert_match "detail is #999" '"detail":"#999"' "$result_json"
}
