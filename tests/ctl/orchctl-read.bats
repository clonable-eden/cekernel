#!/usr/bin/env bats
# orchctl-read.bats — bats-core tests for scripts/ctl/orchctl.sh read subcommands
# (ls / inspect / target resolution / ps / count / usage)
#
# Consolidates (ADR-0017 Decision 4):
#   tests/ctl/test-orchctl.sh       — ls / inspect / target resolution / usage
#   tests/ctl/test-orchctl-ps.sh    — ps command
#   tests/ctl/test-orchctl-count.sh — count command
#
# ps/count are session-ID based (ADR-0016 Phase 2, #547): orchestrator
# liveness maps to `claude agents --json` state via the token captured in
# orchestrator.claude-session-id — orchestrator.pid is gone. #549 (Phase 4:
# agents --json view layer) further evolves the ps contract when it lands.
#
# Mutating subcommands (term/suspend/resume/kill/nice/recover/gc) are
# covered in orchctl-mutating.bats.

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

ORCH_TOKEN_A="aaaa1111-2222-4333-8444-555566667777"
ORCH_TOKEN_B="bbbb2222-3333-4444-8555-666677778888"

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

  mock_claude
}

teardown() {
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

# Register an orchestrator session token for a session dir (ADR-0016
# Phase 2: liveness is session-ID based — no PID file).
make_orchestrator() {
  local ipc_dir="$1" token="$2"
  mkdir -p "$ipc_dir"
  echo "$token" > "${ipc_dir}/orchestrator.claude-session-id"
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

# ── ps (session-ID based, ADR-0016 Phase 2) ──

@test "ps with no sessions prints 'no orchestrators.'" {
  run bash "$ORCHCTL" ps
  assert_eq "ps no sessions" "no orchestrators." "$output"
}

@test "ps with session but no orchestrator.claude-session-id prints 'no orchestrators.'" {
  mkdir -p "$IPC_A"
  run bash "$ORCHCTL" ps
  assert_eq "ps no session token" "no orchestrators." "$output"
}

@test "ps shows session, claude token, and busy state" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" ps
  assert_match "shows session" "$SESSION_A" "$output"
  assert_match "shows claude token" "$ORCH_TOKEN_A" "$output"
  assert_match "shows busy state" "busy" "$output"
}

@test "ps surfaces a blocked session distinctly (ADR-0016)" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 blocked)]"
  run bash "$ORCHCTL" ps
  assert_match "shows blocked state" "blocked" "$output"
}

@test "ps shows missing when the session is not listed" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  # queue empty → agents --json replies []
  run bash "$ORCHCTL" ps
  assert_match "shows missing" "missing" "$output"
}

@test "ps elapsed reads from orchestrator.spawned" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  echo "0" > "${IPC_A}/orchestrator.spawned"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" ps
  assert_match "elapsed from .spawned (epoch 0 → hours)" 'elapsed=[0-9]+h' "$output"
}

@test "ps lists multiple sessions" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$ORCH_TOKEN_B" background /repo 1700000001000 done)
  ]"
  run bash "$ORCHCTL" ps
  local line_count
  line_count=$(echo "$output" | grep -c "orchestrator" || true)
  assert_eq "two orchestrators" "2" "$line_count"
  assert_match "done state shown as-is" "done" "$output"
}

@test "ps --session filters to the given session" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$ORCH_TOKEN_B" background /repo 1700000001000 busy)
  ]"
  run bash "$ORCHCTL" ps --session "$SESSION_B"
  assert_match "shows filtered session" "$SESSION_B" "$output"
  if [[ "$output" == *"$SESSION_A"* ]]; then
    echo "FAIL: ps --session should not show other sessions" >&2
    return 1
  fi
}

@test "ps --session with non-existent session prints 'no orchestrators.'" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  run bash "$ORCHCTL" ps --session "nonexistent-session"
  assert_eq "nonexistent session" "no orchestrators." "$output"
}

@test "ps ignores a legacy orchestrator.pid file (v2 is session-ID based)" {
  mkdir -p "$IPC_A"
  echo "$$" > "${IPC_A}/orchestrator.pid"
  run bash "$ORCHCTL" ps
  assert_eq "legacy pid file alone shows nothing" "no orchestrators." "$output"
}

# ── count (session-ID based, ADR-0016 Phase 2 / ADR-0014) ──

@test "count with no sessions is 0" {
  run bash "$ORCHCTL" count
  assert_eq "count no sessions" "0" "$output"
}

@test "count with session but no orchestrator.claude-session-id is 0" {
  mkdir -p "$IPC_A"
  run bash "$ORCHCTL" count
  assert_eq "count no session token" "0" "$output"
}

@test "count ignores a legacy orchestrator.pid file (v2 is session-ID based)" {
  mkdir -p "$IPC_A"
  echo "$$" > "${IPC_A}/orchestrator.pid"
  run bash "$ORCHCTL" count
  assert_eq "legacy pid file not counted" "0" "$output"
}

@test "count does not count a done or missing session" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  # A is done; B is not listed at all
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 done)]"
  run bash "$ORCHCTL" count
  assert_eq "done/missing not counted" "0" "$output"
}

@test "count counts busy and blocked sessions, ignoring dead ones" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  local ipc_c="${IPC_BASE}/test-orchctl-repo3-00000003"
  make_orchestrator "$ipc_c" "cccc3333-4444-4555-8666-777788889999"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$ORCH_TOKEN_B" background /repo 1700000001000 blocked),
    $(mock_claude_agent_record "cccc3333-4444-4555-8666-777788889999" background /repo 1700000002000 stopped)
  ]"
  run bash "$ORCHCTL" count
  assert_eq "busy + blocked counted, stopped ignored" "2" "$output"
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
