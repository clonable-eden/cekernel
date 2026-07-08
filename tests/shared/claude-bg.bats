#!/usr/bin/env bats
# claude-bg.bats — contract tests for scripts/shared/claude-bg.sh
#
# ADR-0018: claude-bg.sh is the sole owner of the claude CLI surface.
# These tests exercise the predicate contract against EVERY row of the
# observed (status, state) matrix AND the three non-verdict reports
# (not-listed / query-failed / unknown-value) — each must surface as a
# distinct echoed token + exit code, never a coerced alive/dead.
#
# Exit-code contract (mirrored in the claude-bg.sh header):
#   0 — verdict (alive | blocked | done | stopped)
#   3 — not-listed
#   4 — query-failed
#   5 — unknown-value (+ stderr warning: drift must be visible)

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

FULL_UUID="aaaa1111-2222-4333-8444-555566667777"

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  mock_claude
  source "${CEKERNEL_DIR}/scripts/shared/claude-bg.sh"
}

# Enqueue a single-record roster with an explicit (status, state) pair
enqueue_pair() {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$FULL_UUID" background /tmp/x 1700000000000 "$1" "$2")]"
}

# ── claude_bg_token_verdict: matrix rows (verdicts, exit 0) ──

@test "verdict matrix: busy/working is alive" {
  enqueue_pair busy working
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "alive" "$output"
}

@test "verdict matrix: busy with absent state is alive" {
  enqueue_pair busy -
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "alive" "$output"
}

@test "verdict matrix: legacy pre-split state:busy (no status) is alive" {
  enqueue_pair - busy
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "alive" "$output"
}

@test "verdict matrix: idle/blocked is blocked (v2.1.202 shape)" {
  enqueue_pair idle blocked
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "blocked" "$output"
}

@test "verdict matrix: blocked/working is blocked (v2.1.201 shape)" {
  enqueue_pair blocked working
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "blocked" "$output"
}

@test "verdict matrix: legacy pre-split state:blocked (no status) is blocked" {
  enqueue_pair - blocked
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "blocked" "$output"
}

@test "verdict matrix: idle/done is done (#591 — terminality reads state)" {
  # The #591 regression: `.status // .state` read "idle" here and broke
  # terminal detection. The verdict must be done.
  enqueue_pair idle done
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "done" "$output"
}

@test "verdict matrix: absent-status/done is done (--all daemon-restart row)" {
  enqueue_pair - done
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "done" "$output"
}

@test "verdict matrix: idle/stopped and absent/stopped are stopped" {
  enqueue_pair idle stopped
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "idle/stopped exit" "0" "$status"
  assert_eq "idle/stopped verdict" "stopped" "$output"

  enqueue_pair - stopped
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "absent/stopped exit" "0" "$status"
  assert_eq "absent/stopped verdict" "stopped" "$output"
}

# ── Non-verdict reports: distinct, never coerced ──

@test "verdict: absent session reports not-listed with exit 3" {
  mock_claude_enqueue_agents "[]"
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "3" "$status"
  assert_eq "report" "not-listed" "$output"
}

@test "verdict: failing CLI reports query-failed with exit 4" {
  mock_claude_fail_agents
  run claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "4" "$status"
  assert_eq "report" "query-failed" "$output"
}

@test "verdict: out-of-matrix pair reports unknown-value with exit 5 and stderr warning" {
  enqueue_pair idle working
  run --separate-stderr claude_bg_token_verdict "$FULL_UUID"
  assert_eq "exit status" "5" "$status"
  assert_eq "report" "unknown-value" "$output"
  assert_match "stderr warning names the pair" "idle" "$stderr"
  assert_match "stderr warning names the pair" "working" "$stderr"
}

@test "verdict_from_json: malformed body reports query-failed" {
  run claude_bg_token_verdict_from_json "not json at all" "$FULL_UUID"
  assert_eq "exit status" "4" "$status"
  assert_eq "report" "query-failed" "$output"
}

@test "verdict prefix-matches a short-ID token" {
  enqueue_pair busy working
  run claude_bg_token_verdict "aaaa1111"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "alive" "$output"
}

@test "verdict_from_json: does not call the claude CLI" {
  local json
  json="[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_token_verdict_from_json "$json" "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "alive" "$output"
  assert_not_exists "no agents --json call recorded" \
    "${MOCK_CLAUDE_STATE_DIR}/agents-calls"
}

# ── claude_bg_token_alive: boolean projection of the verdict ──

@test "token_alive: busy and blocked are alive; done and not-listed are not" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "busy is alive" "0" "$status"

  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 blocked)]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "blocked is alive" "0" "$status"

  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "done is dead" "1" "$status"

  mock_claude_enqueue_agents "[]"
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "not-listed is dead" "1" "$status"
}

@test "token_alive: query-failed and unknown-value propagate — never coerced to dead" {
  mock_claude_fail_agents
  run claude_bg_token_alive "$FULL_UUID"
  assert_eq "query-failed propagates as 4" "4" "$status"
}

@test "token_alive_from_json: unknown-value propagates as exit 5" {
  local json
  json="[$(mock_claude_agent_record_pair "$FULL_UUID" background /tmp/x 1700000000000 idle working)]"
  run claude_bg_token_alive_from_json "$json" "$FULL_UUID"
  assert_eq "unknown-value propagates as 5" "5" "$status"
}

@test "token_alive_from_json: busy and blocked are alive; done and missing are not" {
  # Pre-fetched body — no CLI call. Single-fetch views (orchctl ps/count)
  # resolve every token against one response (ADR-0016 Phase 4); the
  # verdict vocabulary lives HERE, not in the view layers.
  local json
  json="[
    $(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy),
    $(mock_claude_agent_record "bbbb0000-1111-4222-8333-444455556666" background /tmp/x 1700000001000 blocked),
    $(mock_claude_agent_record "cccc0000-1111-4222-8333-444455556666" background /tmp/x 1700000002000 done)
  ]"

  run claude_bg_token_alive_from_json "$json" "$FULL_UUID"
  assert_eq "busy is alive" "0" "$status"

  run claude_bg_token_alive_from_json "$json" "bbbb0000"
  assert_eq "blocked is alive" "0" "$status"

  run claude_bg_token_alive_from_json "$json" "cccc0000"
  assert_eq "done is dead" "1" "$status"

  run claude_bg_token_alive_from_json "$json" "ffff0000"
  assert_eq "missing is dead" "1" "$status"
}

@test "token_alive_from_json: real live shape (status:busy + state:working) is alive" {
  # Raw literal pins the real v2.1.202 live shape independently of the
  # mock helper.
  local json
  json="[{\"sessionId\":\"$FULL_UUID\",\"kind\":\"background\",\"cwd\":\"/tmp/x\",\"startedAt\":1700000000000,\"status\":\"busy\",\"state\":\"working\"}]"
  run claude_bg_token_alive_from_json "$json" "$FULL_UUID"
  assert_eq "status busy + state working is alive" "0" "$status"
}

# ── claude_bg_spawn (ADR-0018 Decision 1: --bg invocation + spawn-line
#    parsing live in this module) ──

@test "spawn: invokes claude --bg with the given args and echoes the short ID" {
  mock_claude_enqueue_short_id "abcd1234"
  run claude_bg_spawn /tmp --agent myagent "do the thing"
  assert_eq "exit status" "0" "$status"
  assert_eq "short id" "abcd1234" "$output"
  assert_file_exists "bg argv recorded" "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log"
  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --agent" "--agent myagent" "$argv"
  assert_match "argv has the prompt" "do the thing" "$argv"
}

@test "spawn: echoes empty when the spawn line is unparseable (degraded capture)" {
  mock_claude_enqueue_short_id "NOTHEX!!"
  run claude_bg_spawn /tmp "prompt"
  assert_eq "exit status" "0" "$status"
  assert_eq "no short id" "" "$output"
}

@test "spawn: fails when claude --bg fails" {
  # Replace the shim with one that always fails (mock_bin re-registers)
  mock_bin claude 'exit 1'
  run claude_bg_spawn /tmp "prompt"
  assert_eq "exit status" "1" "$status"
}

# ── claude_bg_stop (#621: token truncation + Rule of Repair) ──

@test "stop: full UUID is truncated to short 8-char job ID" {
  run claude_bg_stop "$FULL_UUID"
  assert_eq "exit status" "0" "$status"
  assert_file_exists "stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stopped token" "aaaa1111" "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
}

@test "stop: short ID is passed through unchanged" {
  run claude_bg_stop "abcd5678"
  assert_eq "exit status" "0" "$status"
  assert_file_exists "stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stopped token" "abcd5678" "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
}

@test "stop: empty token is a no-op success" {
  run claude_bg_stop ""
  assert_eq "exit status" "0" "$status"
  assert_not_exists "no stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
}

@test "stop: failure emits a stderr warning (Rule of Repair) but still exits 0" {
  # Replace claude shim with one that fails on stop
  mock_bin claude 'if [ "$1" = "stop" ]; then echo "No job matching" >&2; exit 1; fi'
  run --separate-stderr claude_bg_stop "deadbeef"
  assert_eq "exit status (reap semantics)" "0" "$status"
  assert_match "stderr warns about stop failure" "stop.*failed|Warning.*stop" "$stderr"
}

# ── claude_bg_capture_session_id ──

@test "capture: short ID prefix-matches to the full UUID (primary path)" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_capture_session_id "aaaa1111" /tmp/x
  assert_eq "exit status" "0" "$status"
  assert_eq "full UUID" "$FULL_UUID" "$output"
}

@test "capture: empty short ID falls back to newest background session at cwd" {
  # An interactive session with a newer startedAt at the same cwd must NOT
  # match (kind filter is mandatory — #571), nor an older background one.
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "bbbb0000-1111-4222-8333-444455556666" interactive /tmp/x 1700000099000 busy),
    $(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy),
    $(mock_claude_agent_record "cccc0000-1111-4222-8333-444455556666" background /tmp/x 1699999999000 busy)
  ]"
  run claude_bg_capture_session_id "" /tmp/x
  assert_eq "exit status" "0" "$status"
  assert_eq "newest background at cwd" "$FULL_UUID" "$output"
}

@test "capture: fails when nothing resolves" {
  # queue empty → [] forever
  run claude_bg_capture_session_id "" /tmp/x
  assert_eq "exit status" "1" "$status"
}

# ── claude_bg_wait_terminal (ADR-0016 Phase 3) ──
# Polls to a terminal-for-unattended-supervision verdict. blocked is
# terminal here: an unattended (cron/at) session waiting on a permission
# dialog will never be approved, so waiting longer cannot help.

@test "wait_terminal: echoes done when the session completes" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "done" "$output"
}

@test "wait_terminal: blocked is terminal (unattended permission stall)" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 blocked)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "blocked" "$output"
}

@test "wait_terminal: stopped is terminal" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 stopped)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "stopped" "$output"
}

@test "wait_terminal: echoes timeout when the session never leaves busy" {
  # Non-terminating sequence: the last enqueued response repeats forever
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 busy)]"
  run claude_bg_wait_terminal "$FULL_UUID" 1 1
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "timeout" "$output"
}

@test "wait_terminal: transient missing session keeps polling to terminal" {
  # Daemon restart window: session temporarily absent, then reported done
  mock_claude_enqueue_agents "[]"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_wait_terminal "$FULL_UUID" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "done" "$output"
}

@test "wait_terminal: prefix-matches a short-ID token" {
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background /tmp/x 1700000000000 done)]"
  run claude_bg_wait_terminal "aaaa1111" 0 5
  assert_eq "exit status" "0" "$status"
  assert_eq "final state" "done" "$output"
}
