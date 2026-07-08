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
# Glob-path coverage lives in the legacy tests/shared/test-transcript-locator.sh.

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
