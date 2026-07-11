#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# orchctl-read.bats — bats-core tests for scripts/ctl/orchctl.sh read subcommands
# (ls / target resolution / ps / count / usage)
#
# Consolidates (ADR-0017 Decision 4):
#   tests/ctl/test-orchctl.sh       — ls / target resolution / usage
#   tests/ctl/test-orchctl-ps.sh    — ps command
#   tests/ctl/test-orchctl-count.sh — count command
#
# ps/count are session-ID based (ADR-0016 Phase 2, #547): orchestrator
# liveness maps to `claude agents --json` state via the token captured in
# orchestrator.claude-session-id — orchestrator.pid is gone. #549 (Phase 4)
# makes ps/count a single-fetch view over `claude agents --json`, joining
# managed Worker/Reviewer rows (handle-{issue}.{type} tokens) with
# cekernel-specific columns (issue, phase, priority) per ADR-0015.
#
# Mutating subcommands (term/suspend/resume/kill/nice/recover/gc) are
# covered in orchctl-mutating.bats.

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

ORCH_TOKEN_A="aaaa1111-2222-4333-8444-555566667777"
ORCH_TOKEN_B="bbbb2222-3333-4444-8555-666677778888"
WORKER_TOKEN="dddd4444-5555-4666-8777-888899990000"
REVIEWER_TOKEN="eeee5555-6666-4777-8888-99990000aaaa"

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

# Create a worker (state + priority) in the given session dir.
make_worker() {
  local ipc_dir="$1" issue="$2" state_line="${3:-RUNNING:2026-02-28T10:00:00Z:phase1:implement}"
  mkdir -p "$ipc_dir"
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

# Register a managed session handle (ADR-0016 Phase 4: opaque session
# token in handle-{issue}.{type}).
make_handle() {
  local ipc_dir="$1" issue="$2" type="$3" token="$4"
  mkdir -p "$ipc_dir"
  echo "$token" > "${ipc_dir}/handle-${issue}.${type}"
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

@test "ls elapsed reads from .spawned file (not state file stat)" {
  make_worker "$IPC_A" 10
  echo "worker" > "${IPC_A}/worker-10.type"
  # Epoch 0 in .spawned forces a very large elapsed (many hours).
  echo "0" > "${IPC_A}/worker-10.spawned"
  run bash "$ORCHCTL" ls
  assert_match "elapsed from .spawned (epoch 0 → hours)" '"elapsed":"[0-9]+h' \
    "$(echo "$output" | grep '"issue":10')"
}

# ── Target resolution (via term) ──

@test "resolve: unique issue resolves" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" term 10
  assert_eq "exit 0" "0" "$status"
  [[ -f "${IPC_A}/worker-10.signal" ]] || { echo "FAIL: signal file not written"; return 1; }
}

@test "resolve: non-existent issue errors" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" term 999
  assert_eq "exit 1" "1" "$status"
}

@test "resolve: ambiguous issue errors with candidates" {
  make_worker "$IPC_A" 10
  make_worker "$IPC_B" 10 "RUNNING:2026-02-28T10:00:00Z:test"
  run bash "$ORCHCTL" term 10
  assert_eq "exit 1" "1" "$status"
  assert_match "error shows ambiguous" "ambiguous" "$output"
}

@test "resolve: repo:issue filter matches session-ID prefix" {
  make_worker "$IPC_A" 10
  make_worker "$IPC_B" 10 "RUNNING:2026-02-28T10:00:00Z:test"
  run bash "$ORCHCTL" term test-orchctl-repo1:10
  assert_eq "exit 0" "0" "$status"
  [[ -f "${IPC_A}/worker-10.signal" ]] || { echo "FAIL: signal file not written in correct session"; return 1; }
}

@test "resolve: org/repo filter matches repo metadata file" {
  make_worker "$IPC_A" 10
  echo "clonable-eden/test-repo" > "${IPC_A}/repo"
  run bash "$ORCHCTL" term "clonable-eden/test-repo:10"
  assert_eq "exit 0" "0" "$status"
  [[ -f "${IPC_A}/worker-10.signal" ]] || { echo "FAIL: signal file not written"; return 1; }
}

@test "resolve: explicit --session resolves; wrong issue errors" {
  make_worker "$IPC_A" 10
  run bash "$ORCHCTL" term 10 --session "$SESSION_A"
  assert_eq "--session exit 0" "0" "$status"
  [[ -f "${IPC_A}/worker-10.signal" ]] || { echo "FAIL: signal file not written"; return 1; }

  run bash "$ORCHCTL" term 999 --session "$SESSION_A"
  assert_eq "--session wrong issue: exit 1" "1" "$status"
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

@test "ps outputs JSON Lines with type=orchestrator for orchestrator row" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" ps
  local line
  line=$(echo "$output" | grep '"type":"orchestrator"')
  assert_match "shows session" "$SESSION_A" "$line"
  assert_match "shows claude token" "$ORCH_TOKEN_A" "$line"
  assert_match "shows alive verdict" '"verdict":"alive"' "$line"
  # Verify it's valid JSON
  echo "$line" | jq . >/dev/null 2>&1
  assert_eq "valid JSON" "0" "$?"
}

@test "ps surfaces a blocked session distinctly (ADR-0016)" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 blocked)]"
  run bash "$ORCHCTL" ps
  assert_match "shows blocked verdict" '"verdict":"blocked"' "$output"
}

@test "ps shows not-listed when the session is absent (ADR-0018 vocabulary)" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  # queue empty → agents --json replies []
  run bash "$ORCHCTL" ps
  assert_match "shows not-listed" '"verdict":"not-listed"' "$output"
}

@test "ps elapsed reads from orchestrator.spawned" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  echo "0" > "${IPC_A}/orchestrator.spawned"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" ps
  assert_match "elapsed from .spawned (epoch 0 → hours)" '"elapsed":"[0-9]+h' "$output"
}

@test "ps lists multiple sessions as JSON Lines" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$ORCH_TOKEN_B" background /repo 1700000001000 done)
  ]"
  run bash "$ORCHCTL" ps
  local line_count
  line_count=$(echo "$output" | grep -c '"type":"orchestrator"' || true)
  assert_eq "two orchestrator JSON lines" "2" "$line_count"
  assert_match "done verdict shown" '"verdict":"done"' "$output"
}

@test "ps --session filters to the given session" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$ORCH_TOKEN_B" background /repo 1700000001000 busy)
  ]"
  run bash "$ORCHCTL" ps --session "$SESSION_B"
  assert_match "shows filtered session" '"session":"'"$SESSION_B"'"' "$output"
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

# ── ps managed rows (agents --json view layer, ADR-0016 Phase 4 / #549) ──

@test "ps joins worker row: JSON with issue, phase, priority, verdict" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_worker "$IPC_A" 10
  make_handle "$IPC_A" 10 worker "$WORKER_TOKEN"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$WORKER_TOKEN" background /repo 1700000001000 busy)
  ]"
  run bash "$ORCHCTL" ps
  local worker_line
  worker_line=$(echo "$output" | grep '"issue":10')
  assert_match "row shows type worker" '"type":"worker"' "$worker_line"
  assert_match "row shows claude token" "$WORKER_TOKEN" "$worker_line"
  assert_match "row joins phase from state file" '"phase":"phase1:implement"' "$worker_line"
  assert_match "row joins priority from priority file" '"priority":10' "$worker_line"
  assert_match "row shows alive verdict" '"verdict":"alive"' "$worker_line"
  # Verify valid JSON
  echo "$worker_line" | jq . >/dev/null 2>&1
  assert_eq "valid JSON" "0" "$?"
}

@test "ps surfaces a blocked worker session distinctly (ADR-0016 MUST)" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_worker "$IPC_A" 10
  make_handle "$IPC_A" 10 worker "$WORKER_TOKEN"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$WORKER_TOKEN" background /repo 1700000001000 blocked)
  ]"
  run bash "$ORCHCTL" ps
  assert_match "worker row shows blocked" '"verdict":"blocked"' "$(echo "$output" | grep '"issue":10')"
}

@test "ps shows not-listed for a worker token absent from the roster" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_worker "$IPC_A" 10
  make_handle "$IPC_A" 10 worker "$WORKER_TOKEN"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" ps
  assert_match "worker row shows not-listed" '"verdict":"not-listed"' "$(echo "$output" | grep '"issue":10')"
}

@test "ps shows worker rows in a session without an orchestrator token" {
  # Interactive orchestrators have no orchestrator.claude-session-id,
  # but their spawned workers must still be visible.
  make_worker "$IPC_A" 10
  make_handle "$IPC_A" 10 worker "$WORKER_TOKEN"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$WORKER_TOKEN" background /repo 1700000001000 busy)]"
  run bash "$ORCHCTL" ps
  assert_match "worker row shown" '"issue":10' "$output"
  assert_match "worker row shows alive" '"verdict":"alive"' "$(echo "$output" | grep '"issue":10')"
  if [[ "$output" == *"no orchestrators."* ]]; then
    echo "FAIL: worker rows found — must not print 'no orchestrators.'" >&2
    return 1
  fi
}

@test "ps shows reviewer type from handle-{issue}.reviewer" {
  make_worker "$IPC_A" 11 "RUNNING:2026-02-28T10:00:00Z:reviewing"
  make_handle "$IPC_A" 11 reviewer "$REVIEWER_TOKEN"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$REVIEWER_TOKEN" background /repo 1700000001000 busy)]"
  run bash "$ORCHCTL" ps
  assert_match "row shows type reviewer" '"type":"reviewer"' "$(echo "$output" | grep '"issue":11')"
}

@test "ps --session filter applies to worker rows" {
  make_worker "$IPC_A" 10
  make_handle "$IPC_A" 10 worker "$WORKER_TOKEN"
  make_worker "$IPC_B" 20
  make_handle "$IPC_B" 20 worker "$REVIEWER_TOKEN"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$WORKER_TOKEN" background /repo 1700000001000 busy),
    $(mock_claude_agent_record "$REVIEWER_TOKEN" background /repo 1700000002000 busy)
  ]"
  run bash "$ORCHCTL" ps --session "$SESSION_A"
  assert_match "filtered session worker shown" '"issue":10' "$output"
  if [[ "$output" == *'"issue":20'* ]]; then
    echo "FAIL: ps --session should not show other sessions' workers" >&2
    return 1
  fi
}

@test "ps fetches agents --json exactly once per invocation (single-fetch view)" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_worker "$IPC_A" 10
  make_handle "$IPC_A" 10 worker "$WORKER_TOKEN"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  make_worker "$IPC_B" 20
  make_handle "$IPC_B" 20 worker "$REVIEWER_TOKEN"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$WORKER_TOKEN" background /repo 1700000001000 busy),
    $(mock_claude_agent_record "$ORCH_TOKEN_B" background /repo 1700000002000 busy),
    $(mock_claude_agent_record "$REVIEWER_TOKEN" background /repo 1700000003000 busy)
  ]"
  run bash "$ORCHCTL" ps
  assert_eq "exit 0" "0" "$status"
  assert_eq "agents --json called once" "1" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/agents-calls")"
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

@test "count counts an unknown-value session conservatively (ADR-0018)" {
  # Degradation policy: for a concurrency guard, over-counting is safe
  # (refuses a spawn) and under-counting is not (duplicate orchestrators)
  # — schema drift counts as alive.
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$ORCH_TOKEN_A" background /repo 1700000000000 running active)]"
  run --separate-stderr bash "$ORCHCTL" count
  assert_eq "unknown-value counted as alive" "1" "$output"
}

@test "count fetches agents --json exactly once per invocation (single-fetch view)" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_orchestrator "$IPC_B" "$ORCH_TOKEN_B"
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$ORCH_TOKEN_B" background /repo 1700000001000 busy)
  ]"
  run bash "$ORCHCTL" count
  assert_eq "count busy sessions" "2" "$output"
  assert_eq "agents --json called once" "1" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/agents-calls")"
}

# ── usage ──

# ── ls: ADR-0020 Phase 2 — state-based enumeration ──

@test "ls enumerates by state file (ADR-0020 Phase 2)" {
  mkdir -p "$IPC_A"
  echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${IPC_A}/worker-10.state"
  echo "10" > "${IPC_A}/worker-10.priority"
  run bash "$ORCHCTL" ls
  assert_match "lists worker by state file" '"issue":10' "$output"
  assert_match "shows state RUNNING" '"state":"RUNNING"' "$output"
}

@test "ls excludes TERMINATED workers (ADR-0020 Phase 2)" {
  mkdir -p "$IPC_A"
  echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${IPC_A}/worker-10.state"
  echo "10" > "${IPC_A}/worker-10.priority"
  echo "TERMINATED:2026-02-28T10:00:00Z:ci-passed:55" > "${IPC_A}/worker-20.state"
  echo "10" > "${IPC_A}/worker-20.priority"
  run bash "$ORCHCTL" ls
  local line_count
  line_count=$(echo "$output" | grep -c '"issue"' || true)
  assert_eq "only non-TERMINATED listed" "1" "$line_count"
  assert_match "active worker listed" '"issue":10' "$output"
}

# ── ls: reviewer-*.state surface (#627, ADR-0021 Decision 2) ──

# Helper to create a reviewer state file in a session dir.
make_reviewer_state() {
  local ipc_dir="$1" issue="$2" state_line="${3:-REVIEWING:2026-07-09T10:00:00Z:review:in-progress}"
  mkdir -p "$ipc_dir"
  echo "$state_line" > "${ipc_dir}/reviewer-${issue}.state"
}

@test "ls surfaces reviewer-*.state as type=reviewer row" {
  make_reviewer_state "$IPC_A" 10
  run bash "$ORCHCTL" ls
  assert_match "contains issue 10" '"issue":10' "$output"
  assert_match "type is reviewer" '"type":"reviewer"' "$output"
  assert_match "state is REVIEWING" '"state":"REVIEWING"' "$output"
}

@test "ls excludes TERMINATED reviewer state" {
  make_reviewer_state "$IPC_A" 10
  make_reviewer_state "$IPC_A" 11 "TERMINATED:2026-07-09T10:00:00Z:approved"
  run bash "$ORCHCTL" ls
  local line_count
  line_count=$(echo "$output" | grep -c '"issue"' || true)
  assert_eq "only non-TERMINATED reviewer listed" "1" "$line_count"
  assert_match "active reviewer listed" '"issue":10' "$output"
}

@test "ls shows both worker and reviewer rows" {
  make_worker "$IPC_A" 10
  make_reviewer_state "$IPC_A" 11
  run bash "$ORCHCTL" ls
  local line_count
  line_count=$(echo "$output" | grep -c '"issue"' || true)
  assert_eq "two rows (worker + reviewer)" "2" "$line_count"
  assert_match "worker row" '"issue":10' "$output"
  assert_match "reviewer row" '"issue":11' "$output"
}

@test "ls reviewer row has expected fields (session, repo, issue, type, state, detail)" {
  make_reviewer_state "$IPC_A" 10 "REVIEWING:2026-07-09T10:00:00Z:review:in-progress"
  run bash "$ORCHCTL" ls
  local line
  line=$(echo "$output" | grep '"issue":10')
  assert_match "session" "$SESSION_A" "$line"
  assert_match "type" '"type":"reviewer"' "$line"
  assert_match "state" '"state":"REVIEWING"' "$line"
  assert_match "detail" '"detail":"review:in-progress"' "$line"
}

# ── ps: reviewer-*.state surface (#627) ──

@test "ps shows reviewer row from reviewer-*.state as JSON" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_reviewer_state "$IPC_A" 10
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" ps
  local reviewer_line
  reviewer_line=$(echo "$output" | grep '"issue":10')
  assert_match "row shows type reviewer" '"type":"reviewer"' "$reviewer_line"
  assert_match "row shows state" '"state":"REVIEWING"' "$reviewer_line"
  assert_match "row shows detail" '"detail":"review:in-progress"' "$reviewer_line"
  # Verify valid JSON
  echo "$reviewer_line" | jq . >/dev/null 2>&1
  assert_eq "valid JSON" "0" "$?"
}

@test "ps excludes TERMINATED reviewer from reviewer-*.state" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_reviewer_state "$IPC_A" 10 "TERMINATED:2026-07-09T10:00:00Z:approved"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy)]"
  run bash "$ORCHCTL" ps
  if [[ "$output" == *'"issue":10'* ]]; then
    echo "FAIL: TERMINATED reviewer should not appear in ps" >&2
    return 1
  fi
}

@test "ps shows both worker and reviewer rows as JSON Lines" {
  make_orchestrator "$IPC_A" "$ORCH_TOKEN_A"
  make_worker "$IPC_A" 10
  make_handle "$IPC_A" 10 worker "$WORKER_TOKEN"
  make_reviewer_state "$IPC_A" 11
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "$ORCH_TOKEN_A" background /repo 1700000000000 busy),
    $(mock_claude_agent_record "$WORKER_TOKEN" background /repo 1700000001000 busy)
  ]"
  run bash "$ORCHCTL" ps
  assert_match "worker row" '"issue":10' "$output"
  assert_match "reviewer row" '"issue":11' "$output"
}

@test "ps --session filter applies to reviewer rows" {
  make_reviewer_state "$IPC_A" 10
  make_reviewer_state "$IPC_B" 20
  mock_claude_enqueue_agents "[]"
  run bash "$ORCHCTL" ps --session "$SESSION_A"
  if [[ "$output" == *'"issue":20'* ]]; then
    echo "FAIL: ps --session should not show other sessions' reviewers" >&2
    return 1
  fi
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
