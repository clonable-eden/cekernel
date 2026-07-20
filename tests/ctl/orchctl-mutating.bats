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

  # gc's escalation-residue sweep (#671) enumerates the CWD repo's
  # .worktrees/ — run every test outside any git repo so gc never
  # touches the real repo's worktrees.
  cd "$BATS_TEST_TMPDIR"
}

teardown() {
  cd /
  local p
  for p in $BGPIDS; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$IPC_BASE" "$CEKERNEL_VAR_DIR"
}

# Create a worker (state + priority) in the test session.
make_worker() {
  local issue="$1" state_line="${2:-RUNNING:2026-02-28T10:00:00Z:phase1:implement}"
  mkdir -p "$IPC"
  echo "$state_line" > "${IPC}/worker-${issue}.state"
  echo "10" > "${IPC}/worker-${issue}.priority"
}

worker_state() {
  cat "${IPC}/worker-${1}.state"
}

# ── ADR-0020 Phase 1: resolve_target uses state file, not FIFO ──

@test "resolve_target finds worker by state file (no FIFO needed)" {
  mkdir -p "$IPC"
  # Create state file but NO FIFO
  echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${IPC}/worker-10.state"
  echo "10" > "${IPC}/worker-10.priority"

  # term should find the worker via state file
  run bash "$ORCHCTL" term 10 --session "$SESSION"
  assert_eq "term exits 0 (worker found via state)" "0" "$status"
  assert_file_exists "signal file created" "${IPC}/worker-10.signal"
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
  assert_eq "stop called with truncated job ID (#621)" "${SESSION_TOKEN:0:8}" \
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
  assert_eq "stop called with truncated job ID (#621)" "${SESSION_TOKEN:0:8}" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
  assert_match "tmux window killed" "kill-window -t my-session:1" \
    "$(cat "${BATS_TEST_TMPDIR}/tmux-argv.log")"
}

# ── ADR-0020 Phase 1: kill write-once guard ──

@test "kill does NOT overwrite existing TERMINATED state (write-once)" {
  make_worker 10 "TERMINATED:2026-02-28T10:00:00Z:ci-passed:55"
  run bash "$ORCHCTL" kill 10 --session "$SESSION"
  assert_eq "kill exits 0" "0" "$status"
  # State must still be ci-passed:55, NOT killed
  assert_match "state preserved as ci-passed" "ci-passed:55" "$(worker_state 10)"
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
  assert_eq "stop called with truncated job ID (#621)" "${SESSION_TOKEN:0:8}" \
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

@test "recover refuses a stale-blocked worker (occupied session, ADR-0018 A1)" {
  # Only the gc triple-guard path may treat stale-blocked as reapable —
  # recover must see an occupied session and refuse the crash write.
  mock_claude
  make_worker 10
  echo "headless" > "${IPC}/worker-10.backend"
  echo "$SESSION_TOKEN" > "${IPC}/handle-10.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /tmp/wt 1700000000000 stale-blocked)]"

  run bash "$ORCHCTL" recover 10 --session "$SESSION"
  assert_eq "recover stale-blocked: exit 1" "1" "$status"
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

@test "gc preserves files of active worker (state + live handle)" {
  local session_dir="${IPC_BASE}/session-gc-03"
  mkdir -p "$session_dir"
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
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${live_session}/worker-51.state"
  echo "$$" > "${live_session}/handle-51.worker"
  run bash "$ORCHCTL" gc
  assert_not_exists "empty session dir removed" "$empty_session"
  assert_dir_exists "non-empty session preserved" "$live_session"
}

# ── gc: stale resource cleanup ──

@test "gc removes stale state file when TERMINATED and no handle" {
  local session_dir="${IPC_BASE}/session-gc-stale"
  mkdir -p "$session_dir"
  echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${session_dir}/worker-296.state"
  echo "worker" > "${session_dir}/worker-296.type"
  echo "10" > "${session_dir}/worker-296.priority"
  run bash "$ORCHCTL" gc
  assert_not_exists "state removed" "${session_dir}/worker-296.state"
  assert_not_exists "type removed" "${session_dir}/worker-296.type"
  assert_not_exists "priority removed" "${session_dir}/worker-296.priority"
}

@test "gc reaps NEW state + no handle + past stale timeout (reap write)" {
  local session_dir="${IPC_BASE}/session-gc-stale2"
  mkdir -p "$session_dir"
  echo "NEW:2026-02-28T01:00:00Z:spawning" > "${session_dir}/worker-297.state"
  echo "worker" > "${session_dir}/worker-297.type"
  run env CEKERNEL_GC_STALE_TIMEOUT=0 bash "$ORCHCTL" gc
  # ADR-0020 Phase 2: gc writes TERMINATED:crashed:detected-by-gc for
  # stale non-TERMINATED entries, freeing the slot.
  assert_file_exists "state file exists" "${session_dir}/worker-297.state"
  local state_content
  state_content=$(cat "${session_dir}/worker-297.state")
  assert_match "state written to TERMINATED" "^TERMINATED:" "$state_content"
  assert_match "detail is detected-by-gc" "crashed:detected-by-gc" "$state_content"
}

@test "gc reaps RUNNING state with dead handle PID (reap write)" {
  local session_dir="${IPC_BASE}/session-gc-stale3"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-298.state"
  echo "worker" > "${session_dir}/worker-298.type"
  echo "99999999" > "${session_dir}/handle-298.worker"
  run bash "$ORCHCTL" gc
  # ADR-0020 Phase 2: gc writes TERMINATED:crashed:detected-by-gc
  assert_file_exists "state file exists" "${session_dir}/worker-298.state"
  local state_content
  state_content=$(cat "${session_dir}/worker-298.state")
  assert_match "state written to TERMINATED" "^TERMINATED:" "$state_content"
  assert_match "detail is detected-by-gc" "crashed:detected-by-gc" "$state_content"
}

@test "gc preserves state with live handle" {
  local session_dir="${IPC_BASE}/session-gc-live"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-299.state"
  echo "worker" > "${session_dir}/worker-299.type"
  echo "$$" > "${session_dir}/handle-299.worker"
  run bash "$ORCHCTL" gc
  assert_file_exists "state preserved" "${session_dir}/worker-299.state"
  assert_file_exists "handle preserved" "${session_dir}/handle-299.worker"
}

# ── gc: token-handle liveness (PR #572 follow-up, #573) ──
# v2 handles are opaque session tokens; gc resolves them against
# `claude agents --json` instead of assuming they are always alive.
# A failed query stays conservative (assume alive — never gc on doubt).

@test "gc reaps state when the token handle session is not listed (reap write)" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-token1"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-573.state"
  echo "worker" > "${session_dir}/worker-573.type"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-573.worker"
  # empty agents queue → [] → session not listed → dead
  run bash "$ORCHCTL" gc
  # ADR-0020 Phase 2: gc writes TERMINATED:crashed:detected-by-gc
  assert_file_exists "state file exists" "${session_dir}/worker-573.state"
  local state_content
  state_content=$(cat "${session_dir}/worker-573.state")
  assert_match "state written to TERMINATED" "^TERMINATED:" "$state_content"
  assert_match "detail is detected-by-gc" "crashed:detected-by-gc" "$state_content"
}

@test "gc preserves state when the token handle session is busy" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-token2"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-574.state"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-574.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /tmp/wt 1700000000000 busy)]"
  run bash "$ORCHCTL" gc
  assert_file_exists "state preserved" "${session_dir}/worker-574.state"
  assert_file_exists "live token handle preserved" "${session_dir}/handle-574.worker"
}

@test "gc preserves state with a token handle when the agents query fails" {
  local session_dir="${IPC_BASE}/session-gc-token3"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-575.state"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-575.worker"
  mock_bin claude 'exit 1'
  run bash "$ORCHCTL" gc
  assert_file_exists "state preserved (cannot verify → assume alive)" \
    "${session_dir}/worker-575.state"
  assert_file_exists "token handle preserved" "${session_dir}/handle-575.worker"
}

@test "gc refuses to reap on an unknown (status, state) pair (ADR-0018)" {
  # Degradation policy: schema drift is not evidence of death — gc must
  # never reap on doubt.
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-token4"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-576.state"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-576.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$SESSION_TOKEN" background /tmp/wt 1700000000000 running active)]"
  run bash "$ORCHCTL" gc
  assert_file_exists "state preserved (unknown-value → assume alive)" \
    "${session_dir}/worker-576.state"
  assert_file_exists "token handle preserved" "${session_dir}/handle-576.worker"
}

# ── gc: --dry-run ──

@test "gc --dry-run reports stale resources without removing them" {
  local session_dir="${IPC_BASE}/session-gc-dry"
  mkdir -p "$session_dir"
  echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${session_dir}/worker-300.state"
  local lock_dry="${CEKERNEL_VAR_DIR}/locks/testhash456/60.lock"
  mkdir -p "$lock_dry"
  echo "99999999" > "${lock_dry}/pid"

  run bash "$ORCHCTL" gc --dry-run
  assert_file_exists "stale state preserved" "${session_dir}/worker-300.state"
  assert_dir_exists "stale lock preserved" "$lock_dry"
  assert_match "output indicates dry-run" "dry-run" "$output"
  # State-based specificity: the dry-run must name the stale worker-state
  # resource it would remove (replaces the pre-Phase-3 "stale FIFO" assertion,
  # so a regression in state-based stale detection is caught, not just the
  # generic dry-run banner).
  assert_match "output names the stale worker state" \
    "would remove orphan IPC file.*worker-300\.state" "$output"
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
  echo "export CEKERNEL_SESSION_ID=x" > "${session_dir}/env.sh"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 done)]"

  run bash "$ORCHCTL" gc
  assert_file_exists "lingering done session reaped via claude stop" \
    "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with truncated job ID (#621)" "${SESSION_TOKEN:0:8}" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
  assert_not_exists "orchestrator.claude-session-id removed" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_not_exists "orchestrator.spawned removed" "${session_dir}/orchestrator.spawned"
  assert_not_exists "repo file removed" "${session_dir}/repo"
  assert_not_exists "env.sh removed (#672 — was leaking, blocking rmdir)" \
    "${session_dir}/env.sh"
  assert_not_exists "emptied session dir removed" "$session_dir"
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

# ── gc: stale-blocked orchestrator triple-guard reap (ADR-0018 A1) ──
# A stale-blocked orchestrator (phantom blocked: state:blocked without
# waitingFor) may be reaped ONLY when all three guards hold:
#   1. all child workers are TERMINATED
#   2. the IPC dir is quiescent (no recent file activity)
#   3. the grace period has elapsed (CEKERNEL_GC_STALE_BLOCKED_GRACE)
# Any guard failing → keep, as today. Genuine blocked is never reaped.

# Register a stale-blocked orchestrator session with one child worker
# state, then backdate every file so guards 2+3 hold by default.
make_stale_blocked_orch() {
  local session_dir="$1" worker_state_line="$2"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  echo "1711000000" > "${session_dir}/orchestrator.spawned"
  echo "$worker_state_line" > "${session_dir}/worker-90.state"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 stale-blocked)]"
  # Quiescent IPC dir: every file's mtime is far in the past
  find "$session_dir" -type f -exec touch -t 202601010000 {} +
}

@test "gc reaps a stale-blocked orchestrator when the triple guard holds" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-sb1"
  make_stale_blocked_orch "$session_dir" "TERMINATED:2026-07-01T10:00:00Z:ci-passed:99"

  run env CEKERNEL_GC_STALE_BLOCKED_GRACE=60 bash "$ORCHCTL" gc
  assert_eq "gc exit 0" "0" "$status"
  assert_file_exists "phantom session stopped" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with truncated job ID (#621)" "${SESSION_TOKEN:0:8}" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
  assert_not_exists "orchestrator metadata removed" \
    "${session_dir}/orchestrator.claude-session-id"
}

@test "gc keeps a stale-blocked orchestrator while a child worker is not TERMINATED" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-sb2"
  make_stale_blocked_orch "$session_dir" "RUNNING:2026-07-01T10:00:00Z:phase1:implement"
  # Live handle keeps the RUNNING worker active through gc's worker sweep
  # (a numeric PID handle avoids consuming the mocked agents queue)
  echo "$$" > "${session_dir}/handle-90.worker"

  run env CEKERNEL_GC_STALE_BLOCKED_GRACE=60 bash "$ORCHCTL" gc
  assert_file_exists "orchestrator metadata kept (guard 1 failed)" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_not_exists "no stop for a kept session" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
}

@test "gc keeps a stale-blocked orchestrator when the IPC dir saw recent activity" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-sb3"
  make_stale_blocked_orch "$session_dir" "TERMINATED:2026-07-01T10:00:00Z:ci-passed:99"
  # Fresh mtime on one file → the dir is not quiescent
  touch "${session_dir}/worker-90.state"

  run env CEKERNEL_GC_STALE_BLOCKED_GRACE=60 bash "$ORCHCTL" gc
  assert_file_exists "orchestrator metadata kept (guard 2 failed)" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_not_exists "no stop for a kept session" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
}

@test "gc keeps a stale-blocked orchestrator within the grace period" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-sb4"
  make_stale_blocked_orch "$session_dir" "TERMINATED:2026-07-01T10:00:00Z:ci-passed:99"

  # Grace larger than the backdated mtime age → guard 3 fails
  run env CEKERNEL_GC_STALE_BLOCKED_GRACE=9999999999 bash "$ORCHCTL" gc
  assert_file_exists "orchestrator metadata kept (guard 3 failed)" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_not_exists "no stop for a kept session" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
}

@test "gc never reaps a genuine blocked orchestrator even when the guards would hold" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-sb5"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  echo "TERMINATED:2026-07-01T10:00:00Z:ci-passed:99" > "${session_dir}/worker-90.state"
  # Genuine stall: waiting/blocked WITH waitingFor (logical blocked)
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 blocked)]"
  find "$session_dir" -type f -exec touch -t 202601010000 {} +

  run env CEKERNEL_GC_STALE_BLOCKED_GRACE=0 bash "$ORCHCTL" gc
  assert_file_exists "genuine blocked orchestrator kept" \
    "${session_dir}/orchestrator.claude-session-id"
  assert_not_exists "no stop for a genuine blocked session" \
    "${MOCK_CLAUDE_STATE_DIR}/stop.log"
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

# ── gc: v2 lock liveness — opaque session token holders (#619 Bug 1) ──
# v2 (ADR-0016) writes a session UUID as the lock holder. gc must delegate
# to _issue_lock_holder_alive (which uses claude_bg_token_verdict) instead
# of calling kill -0 directly — kill -0 always fails on non-numeric strings.

@test "gc preserves lock with opaque session token holder when session is alive" {
  mock_claude
  local lock_dir="${CEKERNEL_VAR_DIR}/locks/testhash619/619.lock"
  mkdir -p "$lock_dir"
  echo "$SESSION_TOKEN" > "${lock_dir}/pid"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /tmp/wt 1700000000000 busy)]"
  run bash "$ORCHCTL" gc
  assert_dir_exists "live token-holder lock preserved" "$lock_dir"
}

@test "gc removes lock with opaque session token holder when session is dead" {
  mock_claude
  local lock_dir="${CEKERNEL_VAR_DIR}/locks/testhash619/620.lock"
  mkdir -p "$lock_dir"
  echo "$SESSION_TOKEN" > "${lock_dir}/pid"
  # empty agents queue → [] → session not listed → dead
  run bash "$ORCHCTL" gc
  assert_not_exists "dead token-holder lock removed" "$lock_dir"
}

@test "gc preserves lock with opaque session token when agents query fails (refuse-on-doubt)" {
  local lock_dir="${CEKERNEL_VAR_DIR}/locks/testhash619/621.lock"
  mkdir -p "$lock_dir"
  echo "$SESSION_TOKEN" > "${lock_dir}/pid"
  mock_bin claude 'exit 1'
  run bash "$ORCHCTL" gc
  assert_dir_exists "lock preserved on query failure" "$lock_dir"
}

# ── gc: orphan-log key mismatch (#619 Bug 2) ──
# active_issues records "session_dir:issue" but the log orphan check was
# passing "session_dir/logs/" as sdir, producing "session_dir/logs/:issue"
# which never matches — making all logs appear orphan.

# ── ADR-0020 Phase 1: gc orphan-sweep protection key ──
# Non-TERMINATED state files protect the issue from gc orphan sweep,
# regardless of FIFO existence. This ensures held slots survive gc.

@test "gc preserves non-TERMINATED state files with live handle (held slot survives gc)" {
  local session_dir="${IPC_BASE}/session-gc-held"
  mkdir -p "$session_dir"
  # Non-TERMINATED state + live handle → held slot, must survive
  echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${session_dir}/worker-710.state"
  echo "10" > "${session_dir}/worker-710.priority"
  echo "worker" > "${session_dir}/worker-710.type"
  echo "$$" > "${session_dir}/handle-710.worker"  # live handle
  run bash "$ORCHCTL" gc
  assert_file_exists "held slot state preserved" "${session_dir}/worker-710.state"
  assert_file_exists "held slot priority preserved" "${session_dir}/worker-710.priority"
  assert_file_exists "held slot type preserved" "${session_dir}/worker-710.type"
}

@test "gc removes TERMINATED state files without FIFO (orphan cleanup)" {
  local session_dir="${IPC_BASE}/session-gc-orphterm"
  mkdir -p "$session_dir"
  # TERMINATED state, no FIFO → orphan, should be cleaned
  echo "TERMINATED:2026-02-28T10:00:00Z:ci-passed:99" > "${session_dir}/worker-711.state"
  echo "10" > "${session_dir}/worker-711.priority"
  run bash "$ORCHCTL" gc
  assert_not_exists "orphan TERMINATED state removed" "${session_dir}/worker-711.state"
  assert_not_exists "orphan priority removed" "${session_dir}/worker-711.priority"
}

@test "gc preserves log files of active workers" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-log619"
  mkdir -p "${session_dir}/logs"
  # Create an active worker (state + live handle)
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-622.state"
  echo "$$" > "${session_dir}/handle-622.worker"
  # Create log files for the active worker
  echo "log data" > "${session_dir}/logs/worker-622.log"
  echo "stdout data" > "${session_dir}/logs/worker-622.stdout.log"
  run bash "$ORCHCTL" gc
  assert_file_exists "active worker log preserved" "${session_dir}/logs/worker-622.log"
  assert_file_exists "active worker stdout log preserved" "${session_dir}/logs/worker-622.stdout.log"
}

# ── gc: ADR-0020 Phase 2 — reap writes TERMINATED:crashed:detected-by-gc ──

@test "gc reap writes crashed:detected-by-gc for stale non-TERMINATED worker" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-reap1"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-630.state"
  echo "$SESSION_TOKEN" > "${session_dir}/handle-630.worker"
  # empty agents queue → session not listed → dead
  run bash "$ORCHCTL" gc
  # State should be rewritten to TERMINATED:crashed:detected-by-gc
  assert_file_exists "state file still exists" "${session_dir}/worker-630.state"
  local state_content
  state_content=$(cat "${session_dir}/worker-630.state")
  assert_match "state is TERMINATED" "^TERMINATED:" "$state_content"
  assert_match "detail is crashed:detected-by-gc" "crashed:detected-by-gc" "$state_content"
}

@test "gc reap does NOT overwrite existing TERMINATED state (write-once)" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-reap2"
  mkdir -p "$session_dir"
  echo "TERMINATED:2026-02-28T10:00:00Z:ci-passed:55" > "${session_dir}/worker-631.state"
  # TERMINATED + no live handle → orphan state removed.
  # Write-once: gc must NOT write detected-by-gc over existing TERMINATED.
  # The orphan sweep may later delete the state file (separate concern).
  run bash "$ORCHCTL" gc
  local state_content
  state_content=$(cat "${session_dir}/worker-631.state" 2>/dev/null || true)
  # If the file still exists, it must still say ci-passed (not detected-by-gc).
  # If the file was deleted by orphan sweep, that's also correct (not overwritten).
  if [[ -n "$state_content" ]]; then
    assert_match "state preserved as ci-passed" "ci-passed:55" "$state_content"
  fi
  # Either way, detected-by-gc must NOT appear
  if [[ "$state_content" == *"detected-by-gc"* ]]; then
    echo "FAIL: TERMINATED state was overwritten with detected-by-gc" >&2
    return 1
  fi
}

@test "gc reap writes crashed:detected-by-gc for dead handle PID" {
  local session_dir="${IPC_BASE}/session-gc-reap3"
  mkdir -p "$session_dir"
  echo "RUNNING:2026-02-28T10:00:00Z:working" > "${session_dir}/worker-632.state"
  echo "99999999" > "${session_dir}/handle-632.worker"
  run bash "$ORCHCTL" gc
  assert_file_exists "state file still exists" "${session_dir}/worker-632.state"
  local state_content
  state_content=$(cat "${session_dir}/worker-632.state")
  assert_match "state is TERMINATED" "^TERMINATED:" "$state_content"
  assert_match "detail is crashed:detected-by-gc" "crashed:detected-by-gc" "$state_content"
}

@test "gc reap writes crashed:detected-by-gc for stale NEW past timeout" {
  local session_dir="${IPC_BASE}/session-gc-reap4"
  mkdir -p "$session_dir"
  echo "NEW:2026-02-28T01:00:00Z:spawning" > "${session_dir}/worker-633.state"
  echo "worker" > "${session_dir}/worker-633.type"
  run env CEKERNEL_GC_STALE_TIMEOUT=0 bash "$ORCHCTL" gc
  assert_file_exists "state file still exists" "${session_dir}/worker-633.state"
  local state_content
  state_content=$(cat "${session_dir}/worker-633.state")
  assert_match "state is TERMINATED" "^TERMINATED:" "$state_content"
  assert_match "detail is crashed:detected-by-gc" "crashed:detected-by-gc" "$state_content"
}

# ── gc: reviewer-*.* orphan sweep (#678, supersedes #627 / ADR-0021 OQ2) ──
# ADR-0021 OQ2 originally excluded reviewer state from gc entirely, which
# leaked IPC session dirs forever (rmdir never succeeded — 48 dirs observed).
# New semantics: reviewers are Orchestrator subagents — they can only be
# running while the orchestrator session is alive. gc protects active
# (non-TERMINATED) reviewer state of alive/unverifiable orchestrator
# sessions ("never reap on doubt"); everything else follows the same
# orphan rule as worker files.

@test "gc preserves REVIEWING reviewer state while its orchestrator session is alive" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-rev1"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  echo "REVIEWING:2026-07-09T10:00:00Z:review:in-progress" > "${session_dir}/reviewer-42.state"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" gc
  assert_file_exists "REVIEWING state of live session preserved" \
    "${session_dir}/reviewer-42.state"
}

@test "gc removes reviewer files of a dead orchestrator session and reclaims the dir" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-rev2"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  echo "REVIEWING:2026-07-09T10:00:00Z:review:in-progress" > "${session_dir}/reviewer-42.state"
  echo "TERMINATED:2026-07-09T10:00:00Z:approved" > "${session_dir}/reviewer-43.state"
  echo "1711000000" > "${session_dir}/reviewer-44.spawned"  # legacy artifact
  # empty agents queue → [] → session not listed → verifiably dead
  run bash "$ORCHCTL" gc
  assert_not_exists "REVIEWING state of dead session removed" \
    "${session_dir}/reviewer-42.state"
  assert_not_exists "TERMINATED reviewer state removed" \
    "${session_dir}/reviewer-43.state"
  assert_not_exists "legacy reviewer .spawned removed" \
    "${session_dir}/reviewer-44.spawned"
  assert_not_exists "emptied session dir removed" "$session_dir"
}

@test "gc removes orphan reviewer state when no orchestrator metadata remains" {
  # The reported leak (#678): a previous gc reaped the orchestrator
  # metadata but left reviewer-*.state behind, so rmdir failed forever.
  local session_dir="${IPC_BASE}/session-gc-rev3"
  mkdir -p "$session_dir"
  echo "TERMINATED:2026-07-09T10:00:00Z:approved" > "${session_dir}/reviewer-655.state"
  run bash "$ORCHCTL" gc
  assert_not_exists "orphan reviewer state removed" "${session_dir}/reviewer-655.state"
  assert_not_exists "emptied session dir removed" "$session_dir"
}

@test "gc preserves reviewer state of an issue with an active worker" {
  local session_dir="${IPC_BASE}/session-gc-rev4"
  mkdir -p "$session_dir"
  # Active worker (non-TERMINATED state + live handle) on the same issue
  echo "RUNNING:2026-07-09T10:00:00Z:phase1:implement" > "${session_dir}/worker-60.state"
  echo "$$" > "${session_dir}/handle-60.worker"
  echo "TERMINATED:2026-07-09T10:00:00Z:changes-requested" > "${session_dir}/reviewer-60.state"
  run bash "$ORCHCTL" gc
  assert_file_exists "reviewer state of active issue preserved" \
    "${session_dir}/reviewer-60.state"
}

@test "gc does NOT interfere with reviewer state when reaping stale workers" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-rev5"
  mkdir -p "$session_dir"
  echo "$SESSION_TOKEN" > "${session_dir}/orchestrator.claude-session-id"
  # Stale worker: dead handle
  echo "RUNNING:2026-07-09T10:00:00Z:working" > "${session_dir}/worker-50.state"
  echo "99999999" > "${session_dir}/handle-50.worker"
  # Live reviewer for a different issue, orchestrator session alive
  echo "REVIEWING:2026-07-09T10:00:00Z:review:in-progress" > "${session_dir}/reviewer-51.state"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$SESSION_TOKEN" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" gc
  # Worker should be reaped
  local worker_state
  worker_state=$(cat "${session_dir}/worker-50.state")
  assert_match "stale worker reaped" "^TERMINATED:" "$worker_state"
  # Reviewer should be untouched
  assert_file_exists "reviewer state preserved" "${session_dir}/reviewer-51.state"
  local reviewer_state
  reviewer_state=$(cat "${session_dir}/reviewer-51.state")
  assert_match "reviewer state unchanged" "^REVIEWING:" "$reviewer_state"
}

@test "gc --dry-run reports orphan reviewer files without removing them" {
  local session_dir="${IPC_BASE}/session-gc-rev6"
  mkdir -p "$session_dir"
  echo "TERMINATED:2026-07-09T10:00:00Z:approved" > "${session_dir}/reviewer-70.state"
  run bash "$ORCHCTL" gc --dry-run
  assert_file_exists "dry-run preserves reviewer state" "${session_dir}/reviewer-70.state"
  assert_match "dry-run reports the reviewer file" "reviewer-70.state" "$output"
}

@test "gc removes legacy prefix-less claude-session-id with dead orchestrator metadata" {
  mock_claude
  local session_dir="${IPC_BASE}/session-gc-rev7"
  mkdir -p "$session_dir"
  # Pre-v2 layout: orchestrator.pid + prefix-less claude-session-id
  echo "99999999" > "${session_dir}/orchestrator.pid"
  echo "some-old-session-uuid" > "${session_dir}/claude-session-id"
  run bash "$ORCHCTL" gc
  assert_not_exists "legacy pid file swept" "${session_dir}/orchestrator.pid"
  assert_not_exists "legacy claude-session-id swept" "${session_dir}/claude-session-id"
  assert_not_exists "emptied session dir removed" "$session_dir"
}

# ── gc: escalation-residue sweep — worktree + lock vs PR state (#671) ──
# ADR-0021 Amendment 2 (γ): escalation preserves the worktree and lock for
# human disposition. Once the PR reaches a terminal state (merged/closed),
# gc reclaims both. Degradation policy (ADR-0018): an open PR, a missing
# PR, or a failed gh query all preserve the resources — never reap on doubt.

# Create a temp main repo with a spawn.sh-convention worktree for $1.
# Sets: SWEEP_REPO, SWEEP_ROOT, SWEEP_BRANCH, SWEEP_WT
make_sweep_repo() {
  local issue="$1"
  SWEEP_REPO="${BATS_TEST_TMPDIR}/sweep-repo"
  mkdir -p "$SWEEP_REPO"
  git -C "$SWEEP_REPO" init --quiet
  git -C "$SWEEP_REPO" -c user.name=test -c user.email=test@test \
    commit --allow-empty -m "initial" --quiet
  SWEEP_BRANCH="issue/${issue}-sweep-test"
  SWEEP_WT="${SWEEP_REPO}/.worktrees/${SWEEP_BRANCH}"
  git -C "$SWEEP_REPO" worktree add -b "$SWEEP_BRANCH" "$SWEEP_WT" HEAD --quiet
  # Path as the sweep resolves it (symlink-free), for the lock hash
  SWEEP_ROOT=$(git -C "$SWEEP_REPO" rev-parse --show-toplevel)

  # Isolate cleanup-worktree.sh side effects (trust registry, backend)
  export CLAUDE_JSON="${BATS_TEST_TMPDIR}/claude.json"
  export CEKERNEL_BACKEND=headless
}

# Create an issue lock for $1 with a LIVE holder ($$) — the escalation
# case: section-2's holder-liveness gc must NOT free it; only the
# PR-state sweep may. Sets: SWEEP_LOCK
make_sweep_lock() {
  local issue="$1"
  source "${CEKERNEL_DIR}/scripts/shared/issue-lock.sh"
  local hash
  hash=$(issue_lock_repo_hash "$SWEEP_ROOT")
  SWEEP_LOCK="${CEKERNEL_VAR_DIR}/locks/${hash}/${issue}.lock"
  mkdir -p "$SWEEP_LOCK"
  echo "$$" > "${SWEEP_LOCK}/pid"
}

run_gc_in_repo() {
  run bash -c "cd '$SWEEP_REPO' && bash '$ORCHCTL' gc $*"
}

@test "gc sweep reclaims worktree, branch, and lock when PR is merged" {
  make_sweep_repo 42
  make_sweep_lock 42
  # Worker finished: TERMINATED state counts as inactive
  mkdir -p "$IPC"
  echo "TERMINATED:2026-07-11T10:00:00Z:ci-passed:pr-99" > "${IPC}/worker-42.state"
  mock_bin gh 'echo MERGED'

  run_gc_in_repo
  assert_eq "gc exit 0" "0" "$status"
  assert_not_exists "worktree removed" "$SWEEP_WT"
  assert_eq "local branch deleted" "" \
    "$(git -C "$SWEEP_REPO" branch --list "$SWEEP_BRANCH")"
  assert_not_exists "lock released despite live holder" "$SWEEP_LOCK"
}

@test "gc sweep reclaims worktree when PR is closed (rejected disposition)" {
  make_sweep_repo 43
  # No worker state at all → inactive
  mock_bin gh 'echo CLOSED'

  run_gc_in_repo
  assert_eq "gc exit 0" "0" "$status"
  assert_not_exists "worktree removed" "$SWEEP_WT"
}

@test "gc sweep preserves worktree and lock when PR is open" {
  make_sweep_repo 44
  make_sweep_lock 44
  mock_bin gh 'echo OPEN'

  run_gc_in_repo
  assert_eq "gc exit 0" "0" "$status"
  assert_dir_exists "worktree preserved (open PR = disposition pending)" "$SWEEP_WT"
  assert_dir_exists "lock preserved" "$SWEEP_LOCK"
}

@test "gc sweep preserves worktree and lock when gh fails (cannot verify)" {
  make_sweep_repo 45
  make_sweep_lock 45
  mock_bin gh 'exit 1'

  run_gc_in_repo
  assert_eq "gc exit 0 despite gh failure" "0" "$status"
  assert_dir_exists "worktree preserved (gh failed → never reap on doubt)" "$SWEEP_WT"
  assert_dir_exists "lock preserved" "$SWEEP_LOCK"
}

@test "gc sweep preserves worktree when no PR exists for the branch" {
  make_sweep_repo 46
  mock_bin gh ':'  # empty output, exit 0 — branch has no PR

  run_gc_in_repo
  assert_eq "gc exit 0" "0" "$status"
  assert_dir_exists "worktree preserved (no PR to verify against)" "$SWEEP_WT"
}

@test "gc sweep preserves worktree of an active worker even when PR is merged" {
  make_sweep_repo 47
  mkdir -p "$IPC"
  echo "WAITING:2026-07-11T10:00:00Z:phase3:ci-waiting" > "${IPC}/worker-47.state"
  echo "$$" > "${IPC}/handle-47.worker"  # live handle → not reaped as stale
  mock_bin gh 'echo MERGED'

  run_gc_in_repo
  assert_eq "gc exit 0" "0" "$status"
  assert_dir_exists "worktree preserved (non-TERMINATED worker)" "$SWEEP_WT"
}

@test "gc --dry-run reports sweep candidates without reclaiming" {
  make_sweep_repo 48
  make_sweep_lock 48
  mock_bin gh 'echo MERGED'

  run_gc_in_repo --dry-run
  assert_eq "gc exit 0" "0" "$status"
  assert_dir_exists "worktree preserved in dry-run" "$SWEEP_WT"
  assert_dir_exists "lock preserved in dry-run" "$SWEEP_LOCK"
  assert_match "dry-run names the worktree" "would reclaim worktree" "$output"
  assert_match "dry-run names the lock" "would release lock" "$output"
}
