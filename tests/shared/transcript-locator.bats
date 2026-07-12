#!/usr/bin/env bats
# transcript-locator.bats — bats-core tests for scripts/shared/transcript-locator.sh
#
# Covers the captured-UUID direct lookup (ADR-0016 Phase 1, #528):
# headless spawns persist the session UUID to
# ${var-dir}/ipc/<session>/{type}-{issue}.claude-session-id, so
# transcript_locate_worker can resolve the exact transcript file instead
# of globbing. The glob remains the fallback (degraded short-ID capture,
# pre-v2 sessions).
#
# Also covers orchestrator transcript discovery (subagent path,
# .spawned reverse lookup, locate_all).

load '../helpers/assertions'

UUID="aaaa1111-2222-4333-8444-555566667777"
OTHER_UUID="bbbb0000-1111-4222-8333-444455556666"

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${CEKERNEL_DIR}/scripts/shared/transcript-locator.sh"

  CLAUDE_HOME="${BATS_TEST_TMPDIR}/claude-home"
  VAR_DIR="${BATS_TEST_TMPDIR}/var"
  PROJECT_DIR="${CLAUDE_HOME}/projects/-Users-t-repo--worktrees-issue-42-feat-x"
  IPC_DIR="${VAR_DIR}/ipc/test-session-00000001"
  mkdir -p "$PROJECT_DIR" "$IPC_DIR"

  # Two transcripts in the worker project dir: only $UUID belongs to the
  # captured session (the other could be a stale/parallel session)
  echo '{"type":"test"}' > "${PROJECT_DIR}/${UUID}.jsonl"
  echo '{"type":"test"}' > "${PROJECT_DIR}/${OTHER_UUID}.jsonl"
}

@test "locate_worker prefers the captured UUID over the glob" {
  echo "$UUID" > "${IPC_DIR}/worker-42.claude-session-id"

  run transcript_locate_worker 42 "$CLAUDE_HOME" "$VAR_DIR"
  assert_eq "exit status" "0" "$status"
  assert_match "captured transcript found" "${UUID}\.jsonl" "$output"
  if [[ "$output" == *"${OTHER_UUID}"* ]]; then
    echo "FAIL: glob result must not appear when the UUID resolves: ${output}" >&2
    return 1
  fi
}

@test "locate_worker falls back to the glob when no UUID is recorded" {
  run transcript_locate_worker 42 "$CLAUDE_HOME" "$VAR_DIR"
  assert_eq "exit status" "0" "$status"
  assert_match "glob finds the first transcript" "${UUID}\.jsonl" "$output"
  assert_match "glob finds the second transcript" "${OTHER_UUID}\.jsonl" "$output"
}

@test "locate_worker falls back to the glob for a short-ID token (degraded capture)" {
  echo "deadbeef" > "${IPC_DIR}/worker-42.claude-session-id"

  run transcript_locate_worker 42 "$CLAUDE_HOME" "$VAR_DIR"
  assert_eq "exit status" "0" "$status"
  assert_match "glob finds the transcripts" "${UUID}\.jsonl" "$output"
}

@test "locate_worker still fails when nothing matches" {
  run transcript_locate_worker 99 "$CLAUDE_HOME" "$VAR_DIR"
  assert_eq "exit status" "1" "$status"
}

# ── Orchestrator transcript discovery ──

@test "locate_orchestrator finds subagent transcripts by session ID" {
  local sess_dir="${CLAUDE_HOME}/projects/-Users-t-repo/session-orch1/subagents"
  mkdir -p "$sess_dir"
  touch "${sess_dir}/agent-001.jsonl"
  touch "${sess_dir}/agent-002.jsonl"

  run transcript_locate_orchestrator "session-orch1" "$CLAUDE_HOME" "-Users-t-repo"
  assert_eq "exit 0" "0" "$status"
  local count
  count=$(echo "$output" | wc -l | tr -d ' ')
  assert_eq "finds 2 subagent transcripts" "2" "$count"
}

@test "locate_orchestrator returns exit 1 when session not found" {
  run transcript_locate_orchestrator "nonexistent-session" "$CLAUDE_HOME" "-Users-t-repo"
  assert_eq "exit 1" "1" "$status"
}

@test "locate_orchestrator_by_issue finds transcripts via .spawned reverse lookup" {
  local mock_session="mock-orch-sess"
  local mock_ipc="${VAR_DIR}/ipc/${mock_session}"
  mkdir -p "$mock_ipc"
  touch "${mock_ipc}/worker-42.spawned"

  local sess_dir="${CLAUDE_HOME}/projects/-Users-t-repo/${mock_session}/subagents"
  mkdir -p "$sess_dir"
  touch "${sess_dir}/agent-010.jsonl"

  run transcript_locate_orchestrator_by_issue 42 "$VAR_DIR" "$CLAUDE_HOME" "-Users-t-repo"
  assert_eq "exit 0" "0" "$status"
  assert_match "finds orchestrator transcript" "agent-010\.jsonl" "$output"
}
