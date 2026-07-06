#!/usr/bin/env bats
# orchctl-read.bats — bats-core tests for scripts/ctl/orchctl.sh read subcommands
# (ls / inspect / target resolution / ps / count / usage)
#
# Consolidates (ADR-0017 Decision 4):
#   tests/ctl/test-orchctl.sh       — ls / inspect / target resolution / usage
#   tests/ctl/test-orchctl-ps.sh    — ps command
#   tests/ctl/test-orchctl-count.sh — count command
#
# NOTE: ps/count are tested against current behavior; #549 (Phase 4:
# claude agents --json view layer) replaces their contract when it lands.
#
# Mutating subcommands (term/suspend/resume/kill/nice/recover/gc) are
# covered in orchctl-mutating.bats.

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ORCHCTL="${CEKERNEL_DIR}/scripts/ctl/orchctl.sh"

  # Isolated IPC base: orchctl scans all sessions under CEKERNEL_IPC_BASE,
  # so isolation happens at the base level (per-test mktemp), not per session.
  IPC_BASE=$(mktemp -d)
  export CEKERNEL_IPC_BASE="$IPC_BASE"
  export CEKERNEL_VAR_DIR=$(mktemp -d)

  SESSION_A="test-orchctl-repo1-00000001"
  SESSION_B="test-orchctl-repo2-00000002"
  IPC_A="${IPC_BASE}/${SESSION_A}"
  IPC_B="${IPC_BASE}/${SESSION_B}"

  BGPIDS=""
}

teardown() {
  local p
  for p in $BGPIDS; do
    pkill -P "$p" 2>/dev/null || true  # reap children of process trees
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$IPC_BASE" "$CEKERNEL_VAR_DIR"
}

# Create a worker (FIFO + state + priority) in the given session dir.
make_worker() {
  local ipc_dir="$1" issue="$2" state_line="${3:-RUNNING:2026-02-28T10:00:00Z:phase1:implement}"
  mkdir -p "$ipc_dir"
  mkfifo "${ipc_dir}/worker-${issue}"
  echo "$state_line" > "${ipc_dir}/worker-${issue}.state"
  echo "10" > "${ipc_dir}/worker-${issue}.priority"
}

# Start a long-lived background process; sets SPAWNED_PID and registers it in
# BGPIDS for teardown. Not usable via $(...) — a command-substitution subshell
# would drop the BGPIDS update and leak the process past teardown.
# FDs are detached so bats does not block on the background child.
spawn_bg() {
  sleep 300 </dev/null >/dev/null 2>&1 3>&- &
  SPAWNED_PID=$!
  BGPIDS="$BGPIDS$SPAWNED_PID "
}

# Like spawn_bg, but the process spawns <n> sleeping children (process tree).
spawn_bg_tree() {
  local n="$1" i cmd=""
  for ((i = 0; i < n; i++)); do
    cmd+="sleep 300 & "
  done
  bash -c "${cmd}wait" </dev/null >/dev/null 2>&1 3>&- &
  SPAWNED_PID=$!
  BGPIDS="$BGPIDS$SPAWNED_PID "
}

# Register an orchestrator PID file for a session dir.
make_orchestrator() {
  local ipc_dir="$1" pid="$2"
  mkdir -p "$ipc_dir"
  echo "$pid" > "${ipc_dir}/orchestrator.pid"
  date +%s > "${ipc_dir}/orchestrator.spawned"
}

# ── ls ──

@test "ls with no sessions prints 'no workers.'" {
  run bash "$ORCHCTL" ls
  assert_eq "ls no sessions" "no workers." "$output"
}

@test "ls with empty session prints 'no workers.'" {
  mkdir -p "$IPC_A"
  run bash "$ORCHCTL" ls
  assert_eq "ls empty session" "no workers." "$output"
}

@test "ls one worker: one JSON line with session, issue, state, priority" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" ls
  local line_count
  line_count=$(echo "$output" | grep -c '"issue"' || true)
  assert_eq "one JSON line" "1" "$line_count"
  assert_match "contains session" "$SESSION_A" "$output"
  assert_match "contains issue 10" '"issue":10' "$output"
  assert_match "contains state RUNNING" '"state":"RUNNING"' "$output"
  assert_match "contains priority" '"priority":10' "$output"
}

@test "ls type field reads worker/reviewer from .type file, defaults to unknown" {
  make_worker "$IPC_A" 10
  echo "worker" > "${IPC_A}/worker-10.type"
  make_worker "$IPC_A" 11 "RUNNING:2026-02-28T10:00:00Z:reviewing"
  echo "reviewer" > "${IPC_A}/worker-11.type"
  make_worker "$IPC_A" 12

  run bash "$ORCHCTL" ls
  assert_match "type worker" '"type":"worker"' "$(echo "$output" | grep '"issue":10')"
  assert_match "type reviewer" '"type":"reviewer"' "$(echo "$output" | grep '"issue":11')"
  assert_match "missing type shows unknown" '"type":"unknown"' "$(echo "$output" | grep '"issue":12')"
}

@test "ls across multiple sessions lists all workers" {
  make_worker "$IPC_A" 10
  make_worker "$IPC_B" 20 "WAITING:2026-02-28T10:00:00Z:ci-check"
  run bash "$ORCHCTL" ls
  local line_count
  line_count=$(echo "$output" | grep -c '"issue"' || true)
  assert_eq "two JSON lines" "2" "$line_count"
}

@test "ls backend field reads from metadata file (wezterm/headless/tmux)" {
  make_worker "$IPC_A" 10
  local backend
  for backend in wezterm headless tmux; do
    echo "$backend" > "${IPC_A}/worker-10.backend"
    run bash "$ORCHCTL" ls
    assert_match "backend metadata: ${backend}" "\"backend\":\"${backend}\"" \
      "$(echo "$output" | grep '"issue":10')"
  done
}

@test "ls backend: metadata file overrides stdout.log heuristic" {
  make_worker "$IPC_A" 10
  mkdir -p "${IPC_A}/logs"
  touch "${IPC_A}/logs/worker-10.stdout.log"
  echo "wezterm" > "${IPC_A}/worker-10.backend"
  run bash "$ORCHCTL" ls
  assert_match "metadata overrides heuristic" '"backend":"wezterm"' \
    "$(echo "$output" | grep '"issue":10')"
}

@test "ls backend: no metadata and no handle falls back to unknown" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" ls
  assert_match "no handle → unknown" '"backend":"unknown"' \
    "$(echo "$output" | grep '"issue":10')"
}

@test "ls repo field: metadata file (trimmed) with session-prefix fallback" {
  make_worker "$IPC_A" 10

  echo "clonable-eden/test-repo" > "${IPC_A}/repo"
  run bash "$ORCHCTL" ls
  assert_match "repo from metadata file" '"repo":"clonable-eden/test-repo"' \
    "$(echo "$output" | grep '"issue":10')"

  printf "  clonable-eden/another-repo  \n" > "${IPC_A}/repo"
  run bash "$ORCHCTL" ls
  assert_match "repo metadata trims whitespace" '"repo":"clonable-eden/another-repo"' \
    "$(echo "$output" | grep '"issue":10')"

  rm -f "${IPC_A}/repo"
  run bash "$ORCHCTL" ls
  assert_match "repo falls back to session ID prefix" '"repo":"test-orchctl-repo1"' \
    "$(echo "$output" | grep '"issue":10')"
}

@test "ls elapsed reads from .spawned file (not FIFO stat)" {
  make_worker "$IPC_A" 10
  echo "worker" > "${IPC_A}/worker-10.type"
  # Epoch 0 in .spawned forces a very large elapsed (many hours).
  # FIFO-mtime-based elapsed would report seconds ("Xs") instead.
  echo "0" > "${IPC_A}/worker-10.spawned"
  run bash "$ORCHCTL" ls
  assert_match "elapsed from .spawned (epoch 0 → hours)" '"elapsed":"[0-9]+h' \
    "$(echo "$output" | grep '"issue":10')"
}

# ── Target resolution (via inspect) ──

@test "resolve: unique issue resolves" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" inspect 10
  assert_eq "exit 0" "0" "$status"
  assert_match "resolves issue 10" '"issue":10' "$output"
}

@test "resolve: non-existent issue errors" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" inspect 999
  assert_eq "exit 1" "1" "$status"
}

@test "resolve: ambiguous issue errors with candidates" {
  make_worker "$IPC_A" 10
  make_worker "$IPC_B" 10 "RUNNING:2026-02-28T10:00:00Z:test"
  run bash "$ORCHCTL" inspect 10
  assert_eq "exit 1" "1" "$status"
  assert_match "error shows ambiguous" "ambiguous" "$output"
}

@test "resolve: repo:issue filter matches session-ID prefix" {
  make_worker "$IPC_A" 10
  make_worker "$IPC_B" 10 "RUNNING:2026-02-28T10:00:00Z:test"
  run bash "$ORCHCTL" inspect test-orchctl-repo1:10
  assert_eq "exit 0" "0" "$status"
  assert_match "resolves issue" '"issue":10' "$output"
  assert_match "correct session" "$SESSION_A" "$output"
}

@test "resolve: org/repo filter matches repo metadata file" {
  make_worker "$IPC_A" 10
  echo "clonable-eden/test-repo" > "${IPC_A}/repo"
  run bash "$ORCHCTL" inspect "clonable-eden/test-repo:10"
  assert_eq "exit 0" "0" "$status"
  assert_match "resolves issue" '"issue":10' "$output"
}

@test "resolve: explicit --session resolves; wrong issue errors" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" inspect 10 --session "$SESSION_A"
  assert_eq "--session exit 0" "0" "$status"
  assert_match "resolves issue" '"issue":10' "$output"
  assert_match "correct session" "$SESSION_A" "$output"

  run bash "$ORCHCTL" inspect 999 --session "$SESSION_A"
  assert_eq "--session wrong issue: exit 1" "1" "$status"
}

# ── inspect ──

@test "inspect output contains state, priority, session, type, detail, timestamp" {
  make_worker "$IPC_A" 10
  echo "5" > "${IPC_A}/worker-10.priority"
  echo "worker" > "${IPC_A}/worker-10.type"
  run bash "$ORCHCTL" inspect 10 --session "$SESSION_A"
  assert_match "contains state" '"state":"RUNNING"' "$output"
  assert_match "contains priority" '"priority":5' "$output"
  assert_match "contains session" "$SESSION_A" "$output"
  assert_match "contains type" '"type":"worker"' "$output"
  assert_match "contains detail" '"detail":"phase1:implement"' "$output"
  assert_match "contains timestamp" '"timestamp":"2026-02-28T10:00:00Z"' "$output"
}

@test "inspect output contains backend from metadata file" {
  make_worker "$IPC_A" 10
  echo "headless" > "${IPC_A}/worker-10.backend"
  run bash "$ORCHCTL" inspect 10 --session "$SESSION_A"
  assert_match "backend metadata: headless" '"backend":"headless"' "$output"
}

@test "inspect elapsed reads from .spawned file" {
  make_worker "$IPC_A" 10
  echo "0" > "${IPC_A}/worker-10.spawned"
  run bash "$ORCHCTL" inspect 10 --session "$SESSION_A"
  assert_match "elapsed from .spawned (epoch 0 → hours)" '"elapsed":"[0-9]+h' "$output"
}

# ── ps ──

@test "ps with no sessions prints 'no orchestrators.'" {
  run bash "$ORCHCTL" ps
  assert_eq "ps no sessions" "no orchestrators." "$output"
}

@test "ps with session but no orchestrator.pid prints 'no orchestrators.'" {
  mkdir -p "$IPC_A"
  run bash "$ORCHCTL" ps
  assert_eq "ps no pid file" "no orchestrators." "$output"
}

@test "ps with dead PID shows not-running" {
  make_orchestrator "$IPC_A" 99999
  run bash "$ORCHCTL" ps
  assert_match "dead PID shows not-running" "not-running" "$output"
}

@test "ps with live PID shows session, PID, and running status" {
  spawn_bg
  make_orchestrator "$IPC_A" "$SPAWNED_PID"
  run bash "$ORCHCTL" ps
  assert_match "shows session" "$SESSION_A" "$output"
  assert_match "shows PID" "PID=${SPAWNED_PID}" "$output"
  assert_match "shows running" "running" "$output"
}

@test "ps lists multiple sessions" {
  spawn_bg
  make_orchestrator "$IPC_A" "$SPAWNED_PID"
  spawn_bg
  make_orchestrator "$IPC_B" "$SPAWNED_PID"
  run bash "$ORCHCTL" ps
  local line_count
  line_count=$(echo "$output" | grep -c "orchestrator" || true)
  assert_eq "two orchestrators" "2" "$line_count"
}

@test "ps shows child processes as tree lines" {
  spawn_bg_tree 2
  sleep 0.3  # Give children time to spawn
  make_orchestrator "$IPC_A" "$SPAWNED_PID"

  run bash "$ORCHCTL" ps
  assert_match "shows orchestrator" "orchestrator" "$output"
  local child_lines
  child_lines=$(echo "$output" | grep -cE '├──|└──' || true)
  assert_match "shows child processes" "^[1-9][0-9]*$" "$child_lines"
}

@test "ps --session filters to the given session" {
  spawn_bg
  make_orchestrator "$IPC_A" "$SPAWNED_PID"
  spawn_bg
  make_orchestrator "$IPC_B" "$SPAWNED_PID"
  run bash "$ORCHCTL" ps --session "$SESSION_B"
  assert_match "shows filtered session" "$SESSION_B" "$output"
  if [[ "$output" == *"$SESSION_A"* ]]; then
    echo "FAIL: ps --session should not show other sessions" >&2
    return 1
  fi
}

@test "ps --session with non-existent session prints 'no orchestrators.'" {
  spawn_bg
  make_orchestrator "$IPC_A" "$SPAWNED_PID"
  run bash "$ORCHCTL" ps --session "nonexistent-session"
  assert_eq "nonexistent session" "no orchestrators." "$output"
}

@test "ps shows managed processes from handle files" {
  spawn_bg
  make_orchestrator "$IPC_A" "$SPAWNED_PID"
  spawn_bg
  local managed_pid="$SPAWNED_PID"
  echo "$managed_pid" > "${IPC_A}/handle-999.worker"

  run bash "$ORCHCTL" ps
  assert_match "shows managed marker" '\(managed' "$output"
  assert_match "managed shows PID" "PID=${managed_pid}" "$output"
  assert_match "managed shows issue" "#999" "$output"
  assert_match "managed shows worker type" "worker #999" "$output"
}

@test "ps does not duplicate a child process that also has a handle" {
  spawn_bg_tree 1
  local parent_pid="$SPAWNED_PID"
  sleep 0.3  # Give child time to spawn
  make_orchestrator "$IPC_A" "$parent_pid"

  local child_pid
  child_pid=$(pgrep -P "$parent_pid" 2>/dev/null | head -1)
  if [[ -z "$child_pid" ]]; then
    skip "could not get child PID for dedup test"
  fi
  echo "$child_pid" > "${IPC_A}/handle-888.worker"

  run bash "$ORCHCTL" ps
  local managed_count
  managed_count=$(echo "$output" | grep -c '(managed' || true)
  assert_eq "child+handle not shown as managed" "0" "$managed_count"
}

@test "ps does not show managed process with dead PID" {
  spawn_bg
  make_orchestrator "$IPC_A" "$SPAWNED_PID"
  echo "99999" > "${IPC_A}/handle-777.worker"
  run bash "$ORCHCTL" ps
  local managed_count
  managed_count=$(echo "$output" | grep -c '(managed' || true)
  assert_eq "dead managed not shown" "0" "$managed_count"
}

@test "ps shows multiple managed processes (worker + reviewer)" {
  spawn_bg
  make_orchestrator "$IPC_A" "$SPAWNED_PID"
  spawn_bg
  echo "$SPAWNED_PID" > "${IPC_A}/handle-555.worker"
  spawn_bg
  echo "$SPAWNED_PID" > "${IPC_A}/handle-555.reviewer"

  run bash "$ORCHCTL" ps
  local managed_count
  managed_count=$(echo "$output" | grep -c '(managed' || true)
  assert_eq "both worker and reviewer shown" "2" "$managed_count"
  assert_match "shows worker" "worker #555" "$output"
  assert_match "shows reviewer" "reviewer #555" "$output"
}

# ── count ──

@test "count with no sessions is 0" {
  run bash "$ORCHCTL" count
  assert_eq "count no sessions" "0" "$output"
}

@test "count with session but no orchestrator.pid is 0" {
  mkdir -p "$IPC_A"
  run bash "$ORCHCTL" count
  assert_eq "count no pid file" "0" "$output"
}

@test "count does not count dead PID" {
  mkdir -p "$IPC_A"
  echo "99999" > "${IPC_A}/orchestrator.pid"
  run bash "$ORCHCTL" count
  assert_eq "count dead PID" "0" "$output"
}

@test "count counts live orchestrators across sessions, ignoring dead ones" {
  mkdir -p "$IPC_A"
  spawn_bg
  echo "$SPAWNED_PID" > "${IPC_A}/orchestrator.pid"
  run bash "$ORCHCTL" count
  assert_eq "count 1 live" "1" "$output"

  mkdir -p "$IPC_B"
  spawn_bg
  echo "$SPAWNED_PID" > "${IPC_B}/orchestrator.pid"
  run bash "$ORCHCTL" count
  assert_eq "count 2 live" "2" "$output"

  local ipc_c="${IPC_BASE}/test-orchctl-repo3-00000003"
  mkdir -p "$ipc_c"
  echo "99998" > "${ipc_c}/orchestrator.pid"
  run bash "$ORCHCTL" count
  assert_eq "count 2 live + 1 dead" "2" "$output"
  assert_match "output is a plain integer" '^[0-9]+$' "$output"
}

# ── usage ──

@test "no command prints usage and exits 1" {
  run bash "$ORCHCTL"
  assert_eq "no command: exit 1" "1" "$status"
}

@test "unknown command prints usage and exits 1" {
  run bash "$ORCHCTL" foobar
  assert_eq "unknown command: exit 1" "1" "$status"
}
