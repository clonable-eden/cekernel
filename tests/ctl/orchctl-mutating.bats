#!/usr/bin/env bats
# orchctl-mutating.bats — bats-core tests for scripts/ctl/orchctl.sh mutating
# subcommands (term / suspend / resume / kill / nice / recover / gc)
#
# Consolidates (ADR-0017 Decision 4):
#   tests/ctl/test-orchctl.sh    — term / suspend / resume / kill / nice / recover
#   tests/ctl/test-orchctl-gc.sh — gc command
#
# Read subcommands (ls/inspect/ps/count/usage) are covered in orchctl-read.bats.
#
# Headless handles are opaque session tokens under --bg delegation
# (ADR-0005 Amendment 1, #546): recover verifies liveness via a mocked
# `claude agents --json`, and kill delegates to `claude stop`.

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

SESSION_TOKEN="aaaa1111-2222-4333-8444-555566667777"

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ORCHCTL="${CEKERNEL_DIR}/scripts/ctl/orchctl.sh"

  # Isolated IPC base: orchctl scans all sessions under CEKERNEL_IPC_BASE,
  # so isolation happens at the base level (per-test mktemp), not per session.
  IPC_BASE=$(mktemp -d)
  export CEKERNEL_IPC_BASE="$IPC_BASE"
  export CEKERNEL_VAR_DIR=$(mktemp -d)  # gc also scans ${CEKERNEL_VAR_DIR}/locks

  SESSION="test-orchctl-mut-00000001"
  IPC="${IPC_BASE}/${SESSION}"

  BGPIDS=""
}

teardown() {
  local p
  for p in $BGPIDS; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$IPC_BASE" "$CEKERNEL_VAR_DIR"
}

# Create a worker (FIFO + state + priority) in the test session.
make_worker() {
  local issue="$1" state_line="${2:-RUNNING:2026-02-28T10:00:00Z:phase1:implement}"
  mkdir -p "$IPC"
  mkfifo "${IPC}/worker-${issue}"
  echo "$state_line" > "${IPC}/worker-${issue}.state"
  echo "10" > "${IPC}/worker-${issue}.priority"
}

worker_state() {
  cat "${IPC}/worker-${1}.state"
}

# ── term ──

@test "term creates TERM signal file" {
  make_worker 10
  run bash "$ORCHCTL" term 10 --session "$SESSION"
  assert_eq "term exits 0" "0" "$status"
  assert_file_exists "signal file created" "${IPC}/worker-10.signal"
  assert_eq "signal file contains TERM" "TERM" "$(cat "${IPC}/worker-10.signal")"
}

# ── suspend ──

@test "suspend RUNNING worker creates SUSPEND signal" {
  make_worker 10
  run bash "$ORCHCTL" suspend 10 --session "$SESSION"
  assert_eq "suspend exits 0" "0" "$status"
  assert_file_exists "signal file created" "${IPC}/worker-10.signal"
  assert_eq "signal file contains SUSPEND" "SUSPEND" "$(cat "${IPC}/worker-10.signal")"
}

@test "suspend TERMINATED worker errors without signal file" {
  make_worker 10 "TERMINATED:2026-02-28T10:00:00Z:done"
  run bash "$ORCHCTL" suspend 10 --session "$SESSION"
  assert_eq "suspend TERMINATED: exit 1" "1" "$status"
  assert_not_exists "no signal file" "${IPC}/worker-10.signal"
}

# ── resume ──

@test "resume SUSPENDED worker changes state to READY" {
  make_worker 10 "SUSPENDED:2026-02-28T10:00:00Z:checkpoint-saved"
  run bash "$ORCHCTL" resume 10 --session "$SESSION"
  assert_eq "resume exits 0" "0" "$status"
  assert_match "state changed to READY" "^READY:" "$(worker_state 10)"
}

@test "resume RUNNING worker errors" {
  make_worker 10
  run bash "$ORCHCTL" resume 10 --session "$SESSION"
  assert_eq "resume RUNNING: exit 1" "1" "$status"
}

@test "resume TERMINATED/crashed worker changes state to READY" {
  make_worker 10 "TERMINATED:2026-02-28T10:00:00Z:crashed:detected-by-recover"
  run bash "$ORCHCTL" resume 10 --session "$SESSION"
  assert_eq "resume crashed: exit 0" "0" "$status"
  assert_match "state changed to READY" "^READY:" "$(worker_state 10)"
}

@test "resume TERMINATED/crashed variant changes state to READY" {
  make_worker 10 "TERMINATED:2026-02-28T10:00:00Z:crashed:some-other-reason"
  run bash "$ORCHCTL" resume 10 --session "$SESSION"
  assert_eq "resume crashed variant: exit 0" "0" "$status"
  assert_match "state changed to READY" "^READY:" "$(worker_state 10)"
}

@test "resume TERMINATED (non-crashed) worker errors" {
  make_worker 10 "TERMINATED:2026-02-28T10:00:00Z:completed"
  run bash "$ORCHCTL" resume 10 --session "$SESSION"
  assert_eq "resume completed: exit 1" "1" "$status"
}

# ── nice ──

@test "nice changes priority by name and by number" {
  make_worker 10
  run bash "$ORCHCTL" nice 10 high --session "$SESSION"
  assert_eq "nice high: exit 0" "0" "$status"
  assert_eq "priority is 5" "5" "$(tr -d '[:space:]' < "${IPC}/worker-10.priority")"

  run bash "$ORCHCTL" nice 10 3 --session "$SESSION"
  assert_eq "nice 3: exit 0" "0" "$status"
  assert_eq "priority is 3" "3" "$(tr -d '[:space:]' < "${IPC}/worker-10.priority")"
}

@test "nice with invalid priority errors" {
  make_worker 10
  run bash "$ORCHCTL" nice 10 invalid --session "$SESSION"
  assert_eq "nice invalid: exit 1" "1" "$status"
}

# ── kill ──

@test "kill marks worker as TERMINATED:killed" {
  make_worker 10
  run bash "$ORCHCTL" kill 10 --session "$SESSION"
  assert_eq "kill exits 0" "0" "$status"
  assert_match "state is TERMINATED" "^TERMINATED:" "$(worker_state 10)"
  assert_match "detail says killed" ":killed$" "$(worker_state 10)"
}

@test "kill stops a headless session via claude stop (v2 contract)" {
  mock_claude
  make_worker 10
  echo "headless" > "${IPC}/worker-10.backend"
  echo "$SESSION_TOKEN" > "${IPC}/handle-10.worker"
  run bash "$ORCHCTL" kill 10 --session "$SESSION"
  assert_eq "kill exits 0" "0" "$status"
  assert_file_exists "claude stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with the session token" "$SESSION_TOKEN" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
}

# ADR-0016 Phase 5: terminal backends also hold opaque session tokens as
# handles; the pane lives in pane-{issue}.{type}. kill must stop the
# session (claude stop) AND close the visualization pane/window.
@test "kill stops a tmux-backend session AND kills the window (Phase 5 contract)" {
  mock_claude
  mock_bin tmux "echo \"\$*\" >> \"${BATS_TEST_TMPDIR}/tmux-argv.log\""
  make_worker 10
  echo "tmux" > "${IPC}/worker-10.backend"
  echo "$SESSION_TOKEN" > "${IPC}/handle-10.worker"
  echo "my-session:1.0" > "${IPC}/pane-10.worker"
  run bash "$ORCHCTL" kill 10 --session "$SESSION"
  assert_eq "kill exits 0" "0" "$status"
  assert_file_exists "claude stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with the session token" "$SESSION_TOKEN" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
  assert_match "tmux window killed" "kill-window -t my-session:1" \
    "$(cat "${BATS_TEST_TMPDIR}/tmux-argv.log")"
}

@test "kill stops a wezterm-backend session AND kills the pane (Phase 5 contract)" {
  mock_claude
  mock_bin wezterm "echo \"\$*\" >> \"${BATS_TEST_TMPDIR}/wezterm-argv.log\""
  make_worker 10
  echo "wezterm" > "${IPC}/worker-10.backend"
  echo "$SESSION_TOKEN" > "${IPC}/handle-10.worker"
  echo "42" > "${IPC}/pane-10.worker"
  run bash "$ORCHCTL" kill 10 --session "$SESSION"
  assert_eq "kill exits 0" "0" "$status"
  assert_file_exists "claude stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with the session token" "$SESSION_TOKEN" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
  assert_match "wezterm pane killed" "cli kill-pane --pane-id 42" \
    "$(cat "${BATS_TEST_TMPDIR}/wezterm-argv.log")"
}

# ── recover ──

@test "recover dead RUNNING worker marks TERMINATED/crashed" {
  mock_claude
  make_worker 10
  echo "headless" > "${IPC}/worker-10.backend"
  echo "$SESSION_TOKEN" > "${IPC}/handle-10.worker"
  # empty agents queue → [] → session not listed → dead
  run bash "$ORCHCTL" recover 10 --session "$SESSION"
  assert_eq "recover dead: exit 0" "0" "$status"
  assert_match "state is TERMINATED" "^TERMINATED:" "$(worker_state 10)"
  assert_match "detail is crashed:detected-by-recover" "crashed:detected-by-recover$" "$(worker_state 10)"
}

@test "recover alive worker errors and leaves state unchanged" {
  mock_claude
  make_worker 10
  echo "headless" > "${IPC}/worker-10.backend"
  echo "$SESSION_TOKEN" > "${IPC}/handle-10.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /tmp/wt 1700000000000 busy)]"

  run bash "$ORCHCTL" recover 10 --session "$SESSION"
  assert_eq "recover alive: exit 1" "1" "$status"
  assert_match "state unchanged (RUNNING)" "^RUNNING:" "$(worker_state 10)"
}

@test "recover non-RUNNING worker errors" {
  make_worker 10 "TERMINATED:2026-02-28T10:00:00Z:done"
  echo "99999" > "${IPC}/handle-10.worker"
  run bash "$ORCHCTL" recover 10 --session "$SESSION"
  assert_eq "recover TERMINATED: exit 1" "1" "$status"
}

@test "recover unknown backend (no handle, no .backend) treats worker as dead" {
  make_worker 10
  run bash "$ORCHCTL" recover 10 --session "$SESSION"
  assert_eq "recover unknown backend: exit 0" "0" "$status"
  assert_match "state is TERMINATED" "^TERMINATED:" "$(worker_state 10)"
  assert_match "detail is crashed" "crashed:detected-by-recover$" "$(worker_state 10)"
}

# ── gc: basic behavior ──

@test "gc with no stale resources exits 0 with 'nothing to clean'" {
  mkdir -p "${IPC_BASE}/session-gc-01"
  run bash "$ORCHCTL" gc
  assert_eq "gc exit 0" "0" "$status"
  assert_match "nothing to clean" "nothing to clean" "$output"
}

# ── gc: stale lock cleanup ──

@test "gc removes stale lock (dead PID) and lock dir without PID file" {
  local lock_dead="${CEKERNEL_VAR_DIR}/locks/testhash123/42.lock"
  local lock_nopid="${CEKERNEL_VAR_DIR}/locks/testhash123/44.lock"
  mkdir -p "$lock_dead" "$lock_nopid"
  echo "99999999" > "${lock_dead}/pid"
  run bash "$ORCHCTL" gc
  assert_not_exists "stale lock removed" "$lock_dead"
  assert_not_exists "lock without pid removed" "$lock_nopid"
}

@test "gc preserves lock with live PID" {
  local lock_live="${CEKERNEL_VAR_DIR}/locks/testhash123/43.lock"
  mkdir -p "$lock_live"
  echo "$$" > "${lock_live}/pid"
  run bash "$ORCHCTL" gc
  assert_dir_exists "live lock preserved" "$lock_live"
}

@test "gc removes empty repo-hash directory under locks" {
  local empty_hash="${CEKERNEL_VAR_DIR}/locks/emptyhash000"
  mkdir -p "$empty_hash"
  run bash "$ORCHCTL" gc
  assert_not_exists "empty repo-hash dir removed" "$empty_hash"
}

# ── gc: orphan IPC file cleanup ──

@test "gc removes orphan state/priority/type/signal files (no FIFO)" {
  local session_dir="${IPC_BASE}/session-gc-02"
  mkdir -p "$session_dir"
  echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${session_dir}/worker-50.state"
  echo "5" > "${session_dir}/worker-50.priority"
  echo "worker" > "${session_dir}/worker-50.type"
  echo "TERM" > "${session_dir}/worker-50.signal"
  run bash "$ORCHCTL" gc
  assert_not_exists "orphan state removed" "${session_dir}/worker-50.state"
  assert_not_exists "orphan priority removed" "${session_dir}/worker-50.priority"
  assert_not_exists "orphan type removed" "${session_dir}/worker-50.type"
  assert_not_exists "orphan signal removed" "${session_dir}/worker-50.signal"
}

@test "gc preserves files of active worker (FIFO + live handle)" {
  local session_dir="${IPC_BASE}/session-gc-03"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-51"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-51.state"
  echo "10" > "${session_dir}/worker-51.priority"
  echo "worker" > "${session_dir}/worker-51.type"
  echo "$$" > "${session_dir}/handle-51.worker"  # live handle → active worker
  run bash "$ORCHCTL" gc
  assert_file_exists "state preserved" "${session_dir}/worker-51.state"
  assert_file_exists "priority preserved" "${session_dir}/worker-51.priority"
  assert_file_exists "type preserved" "${session_dir}/worker-51.type"
}

@test "gc removes orphan handle, payload, and log files" {
  local session_dir="${IPC_BASE}/session-gc-02"
  mkdir -p "${session_dir}/logs"
  echo "12345" > "${session_dir}/handle-50.worker"
  echo "base64data" > "${session_dir}/payload-50.b64"
  echo "log data" > "${session_dir}/logs/worker-50.log"
  echo "stdout data" > "${session_dir}/logs/worker-50.stdout.log"
  run bash "$ORCHCTL" gc
  assert_not_exists "orphan handle removed" "${session_dir}/handle-50.worker"
  assert_not_exists "orphan payload removed" "${session_dir}/payload-50.b64"
  assert_not_exists "orphan log removed" "${session_dir}/logs/worker-50.log"
  assert_not_exists "orphan stdout log removed" "${session_dir}/logs/worker-50.stdout.log"
}

# ── gc: empty session directory cleanup ──

@test "gc removes empty session dir, preserves non-empty one" {
  local empty_session="${IPC_BASE}/session-gc-empty"
  local live_session="${IPC_BASE}/session-gc-03"
  mkdir -p "$empty_session" "$live_session"
  mkfifo "${live_session}/worker-51"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${live_session}/worker-51.state"
  echo "$$" > "${live_session}/handle-51.worker"
  run bash "$ORCHCTL" gc
  assert_not_exists "empty session dir removed" "$empty_session"
  assert_dir_exists "non-empty session preserved" "$live_session"
}

# ── gc: stale FIFO cleanup (issue #303) ──

@test "gc removes stale FIFO when TERMINATED and no handle" {
  local session_dir="${IPC_BASE}/session-gc-stale"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-296"
  echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${session_dir}/worker-296.state"
  echo "worker" > "${session_dir}/worker-296.type"
  echo "10" > "${session_dir}/worker-296.priority"
  run bash "$ORCHCTL" gc
  assert_not_exists "stale FIFO removed" "${session_dir}/worker-296"
  assert_not_exists "state removed" "${session_dir}/worker-296.state"
  assert_not_exists "type removed" "${session_dir}/worker-296.type"
  assert_not_exists "priority removed" "${session_dir}/worker-296.priority"
}

@test "gc removes stale FIFO when NEW + no handle + past stale timeout" {
  local session_dir="${IPC_BASE}/session-gc-stale2"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-297"
  echo "NEW:2026-02-28T01:00:00Z:spawning" > "${session_dir}/worker-297.state"
  echo "worker" > "${session_dir}/worker-297.type"
  run env CEKERNEL_GC_STALE_TIMEOUT=0 bash "$ORCHCTL" gc
  assert_not_exists "stale NEW FIFO removed" "${session_dir}/worker-297"
  assert_not_exists "state removed" "${session_dir}/worker-297.state"
  assert_not_exists "type removed" "${session_dir}/worker-297.type"
}

@test "gc removes stale FIFO with dead handle PID" {
  local session_dir="${IPC_BASE}/session-gc-stale3"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-298"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-298.state"
  echo "worker" > "${session_dir}/worker-298.type"
  echo "99999999" > "${session_dir}/handle-298.worker"
  run bash "$ORCHCTL" gc
  assert_not_exists "stale FIFO removed" "${session_dir}/worker-298"
  assert_not_exists "state removed" "${session_dir}/worker-298.state"
  assert_not_exists "dead handle removed" "${session_dir}/handle-298.worker"
}

@test "gc preserves FIFO with live handle" {
  local session_dir="${IPC_BASE}/session-gc-live"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-299"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-299.state"
  echo "worker" > "${session_dir}/worker-299.type"
  echo "$$" > "${session_dir}/handle-299.worker"
  run bash "$ORCHCTL" gc
  assert_fifo_exists "FIFO preserved" "${session_dir}/worker-299"
  assert_file_exists "state preserved" "${session_dir}/worker-299.state"
  assert_file_exists "handle preserved" "${session_dir}/handle-299.worker"
}

# ── gc: token-handle liveness (PR #572 follow-up, #573) ──
# v2 handles are opaque session tokens; gc resolves them against
# `claude agents --json` instead of assuming they are always alive.
# A failed query stays conservative (assume alive — never gc on doubt).

@test "gc removes stale FIFO when the token handle session is not listed" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-token1"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-573"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-573.state"
  echo "worker" > "${session_dir}/worker-573.type"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-573.worker"
  # empty agents queue → [] → session not listed → dead
  run bash "$ORCHCTL" gc
  assert_not_exists "stale FIFO removed" "${session_dir}/worker-573"
  assert_not_exists "state removed" "${session_dir}/worker-573.state"
  assert_not_exists "dead token handle removed" "${session_dir}/handle-573.worker"
}

@test "gc preserves FIFO when the token handle session is busy" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-token2"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-574"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-574.state"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-574.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /tmp/wt 1700000000000 busy)]"
  run bash "$ORCHCTL" gc
  assert_fifo_exists "FIFO preserved" "${session_dir}/worker-574"
  assert_file_exists "live token handle preserved" "${session_dir}/handle-574.worker"
}

@test "gc preserves FIFO with a token handle when the agents query fails" {
  local session_dir="${IPC_BASE}/session-gc-token3"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-575"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-575.state"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-575.worker"
  mock_bin claude 'exit 1'
  run bash "$ORCHCTL" gc
  assert_fifo_exists "FIFO preserved (cannot verify → assume alive)" \
    "${session_dir}/worker-575"
  assert_file_exists "token handle preserved" "${session_dir}/handle-575.worker"
}

@test "gc refuses to reap on an unknown (status, state) pair (ADR-0018)" {
  # Degradation policy: schema drift is not evidence of death — gc must
  # never reap on doubt.
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-token4"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-576"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-576.state"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-576.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$SESSION_TOKEN" background /tmp/wt 1700000000000 idle working)]"
  run bash "$ORCHCTL" gc
  assert_fifo_exists "FIFO preserved (unknown-value → assume alive)" \
    "${session_dir}/worker-576"
  assert_file_exists "token handle preserved" "${session_dir}/handle-576.worker"
}

# ── gc: --dry-run ──

@test "gc --dry-run reports stale resources without removing them" {
  local session_dir="${IPC_BASE}/session-gc-dry"
  mkdir -p "$session_dir"
  mkfifo "${session_dir}/worker-300"
  echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${session_dir}/worker-300.state"
  local lock_dry="${CEKERNEL_VAR_DIR}/locks/testhash456/60.lock"
  mkdir -p "$lock_dry"
  echo "99999999" > "${lock_dry}/pid"

  run bash "$ORCHCTL" gc --dry-run
  assert_fifo_exists "stale FIFO preserved" "${session_dir}/worker-300"
  assert_dir_exists "stale lock preserved" "$lock_dry"
  assert_match "output mentions stale FIFO" "stale FIFO" "$output"
  assert_match "output indicates dry-run" "dry-run" "$output"
}

# ── gc: output summary ──

@test "gc output includes cleaned count" {
  local session_dir="${IPC_BASE}/session-gc-sum"
  mkdir -p "$session_dir"
  echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${session_dir}/worker-70.state"
  local lock_sum="${CEKERNEL_VAR_DIR}/locks/testhash789/70.lock"
  mkdir -p "$lock_sum"
  echo "99999999" > "${lock_sum}/pid"
  run bash "$ORCHCTL" gc
  assert_match "output includes cleaned count" "cleaned" "$output"
}

# ── gc: stale orchestrator session cleanup (ADR-0016 Phase 2) ──
# Orchestrator liveness is session-ID based. A dead session (done/stopped/
# unlisted) is reaped via `claude stop` — done sessions linger until
# explicitly stopped (ADR-0016) — and its metadata files are removed.

@test "gc stops and removes a dead orchestrator session's metadata" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-orch1"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  echo "1711000000" > "${session_dir}/orchestrator.spawned"
  echo "my-repo" > "${session_dir}/repo"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 done)]"

  run bash "$ORCHCTL" gc
  assert_file_exists "lingering done session reaped via claude stop" \
    "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with the token" "$SESSION_TOKEN" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
  assert_not_exists "orchestrator.claude-session-id removed" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_not_exists "orchestrator.spawned removed" "${session_dir}/orchestrator.spawned"
  assert_not_exists "repo file removed" "${session_dir}/repo"
}

@test "gc preserves orchestrator metadata when the session is alive (busy/blocked)" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-orch2"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 busy)]"

  run bash "$ORCHCTL" gc
  assert_file_exists "live orchestrator metadata preserved" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_not_exists "no stop for a live session" "${MOCK_CLAUDE_STATE_DIR}/stop.log"

  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 blocked)]"
  run bash "$ORCHCTL" gc
  assert_file_exists "blocked orchestrator metadata preserved" \
    "${session_dir}/orchestrator.claude-session-id"
}

@test "gc --dry-run preserves stale orchestrator metadata and does not stop" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-orch5"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  echo "1711000000" > "${session_dir}/orchestrator.spawned"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 done)]"

  run bash "$ORCHCTL" gc --dry-run
  assert_file_exists "stale claude-session-id preserved" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_file_exists "stale orchestrator.spawned preserved" \
    "${session_dir}/orchestrator.spawned"
  assert_not_exists "dry-run must not stop the session" \
    "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_match "output mentions orchestrator metadata" \
    "orchestrator.claude-session-id" "$output"
}

@test "gc removes empty session dir after orchestrator session cleanup" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-orch6"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  echo "1711000000" > "${session_dir}/orchestrator.spawned"
  # queue empty → agents --json replies [] → session missing → dead

  run bash "$ORCHCTL" gc
  assert_not_exists "session dir removed after cleanup" "$session_dir"
}

@test "gc removes a legacy orchestrator.pid file (v2 is session-ID based)" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-orch7"
  mkdir -p "$session_dir"
  echo "$$" > "${session_dir}/orchestrator.pid"

  run bash "$ORCHCTL" gc
  assert_not_exists "legacy pid file swept" "${session_dir}/orchestrator.pid"
}
