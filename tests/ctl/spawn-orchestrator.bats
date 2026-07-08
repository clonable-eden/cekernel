#!/usr/bin/env bats
# spawn-orchestrator.bats — v2 contract tests for scripts/ctl/spawn-orchestrator.sh
#
# ADR-0016 Phase 2: Orchestrator spawn delegates to `claude --bg --agent`.
# The daemon-assigned session ID is captured (never injected) and persisted
# deterministically to orchestrator.claude-session-id at spawn time —
# replacing both orchestrator.pid liveness management and the startup
# discovery heuristic that caused the concurrent-session mis-attribution
# bug (#571). Asserts recorded argv and executed effects via the canonical
# mock-claude shim (ADR-0017) — never generated script text.

load '../helpers/assertions'
load '../helpers/session'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

FULL_UUID="aaaa1111-2222-4333-8444-555566667777"

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SPAWN="${CEKERNEL_DIR}/scripts/ctl/spawn-orchestrator.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"

  # --bare requires an explicit auth path (ADR-0016 Amendment 1)
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL CEKERNEL_AGENT_ORCHESTRATOR

  mock_claude

  # spawn-orchestrator resolves the repo root via git — use a real temp repo
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  # agents --json reports realpath'd cwd (verified v2.1.201)
  REPO_REAL="$(cd "$REPO" && pwd -P)"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

# Run spawn-orchestrator.sh from inside the temp repo.
run_spawn() {
  run bash -c "cd '$REPO' && bash '$SPAWN' \"\$@\"" bash "$@"
}

# Enqueue the happy-path capture fixtures: short ID + matching agents record.
enqueue_capture() {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$REPO_REAL" 1700000000000 busy)]"
}

# ── argv contract ──

@test "spawn launches claude --bg with agent, bare flags, and prompt" {
  enqueue_capture
  run_spawn "test prompt"
  assert_eq "exit status" "0" "$status"

  assert_file_exists "bg argv recorded" "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log"
  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --bg" "--bg" "$argv"
  assert_match "argv has --agent orchestrator" "--agent orchestrator" "$argv"
  assert_match "argv has --bare" "--bare" "$argv"
  assert_match "argv has the prompt" "test prompt" "$argv"
}

@test "spawn does NOT use the removed -p print mode" {
  enqueue_capture
  run_spawn "test prompt"

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  if [[ "$argv" =~ (^|[[:space:]])-p([[:space:]]|$) ]]; then
    echo "FAIL: -p must not appear in claude argv: ${argv}" >&2
    return 1
  fi
}

@test "spawn passes CEKERNEL_AGENT_ORCHESTRATOR as the agent name" {
  enqueue_capture
  export CEKERNEL_AGENT_ORCHESTRATOR="cekernel:orchestrator"
  run_spawn "test prompt"

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --agent cekernel:orchestrator" \
    "--agent cekernel:orchestrator" "$argv"
}

@test "spawn requires a prompt argument" {
  run_spawn
  assert_eq "missing prompt: non-zero exit" "1" "$status"
}

# ── session-ID capture (ADR-0016 normative order) ──

@test "spawn persists the captured full UUID to orchestrator.claude-session-id" {
  enqueue_capture
  run_spawn "test prompt"
  assert_eq "exit status" "0" "$status"

  assert_file_exists "claude-session-id written at spawn time" \
    "${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id"
  assert_eq "persisted UUID" "$FULL_UUID" \
    "$(cat "${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id")"
}

@test "spawn outputs the captured session token on stdout" {
  enqueue_capture
  run_spawn "test prompt"
  assert_eq "exit status" "0" "$status"
  assert_match "stdout carries the session token" "$FULL_UUID" "$output"
}

@test "spawn falls back to kind+cwd+startedAt when stdout parse fails" {
  # Non-hex short ID → stdout parse rejects it → fallback path.
  mock_claude_enqueue_short_id "zzzzzzzz"
  # An interactive session at the repo root with a NEWER startedAt must NOT
  # match — the kind filter is exactly the #571 structural fix: the
  # Orchestrator shares the repo-root cwd with interactive sessions.
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "bbbb0000-1111-4222-8333-444455556666" interactive "$REPO_REAL" 1700000099000 busy),
    $(mock_claude_agent_record "$FULL_UUID" background "$REPO_REAL" 1700000000000 busy)
  ]"

  run_spawn "test prompt"
  assert_eq "exit status" "0" "$status"
  assert_eq "captured the background session, not the interactive one" \
    "$FULL_UUID" "$(cat "${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id")"
}

@test "spawn degrades to the short ID when agents --json has no match" {
  # Default queue: short ID "deadbeef", agents --json replies []
  run_spawn "test prompt"
  assert_eq "exit status" "0" "$status"
  assert_eq "degrades to the short ID" "deadbeef" \
    "$(cat "${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id")"
}

@test "spawn fails when neither short ID nor cwd fallback resolves" {
  mock_claude_enqueue_short_id "zzzzzzzz"
  # queue empty → agents --json replies [] forever

  run_spawn "test prompt"
  assert_eq "spawn fails" "1" "$status"
  assert_not_exists "no claude-session-id on capture failure" \
    "${CEKERNEL_IPC_DIR}/orchestrator.claude-session-id"
}

# ── PID management removal (session-ID based management) ──

@test "spawn does NOT write orchestrator.pid" {
  enqueue_capture
  run_spawn "test prompt"
  assert_eq "exit status" "0" "$status"
  assert_not_exists "no PID file under session-ID management" \
    "${CEKERNEL_IPC_DIR}/orchestrator.pid"
}

@test "spawn records the spawn epoch to orchestrator.spawned" {
  enqueue_capture
  run_spawn "test prompt"

  assert_file_exists "spawn marker written" \
    "${CEKERNEL_IPC_DIR}/orchestrator.spawned"
  assert_match "spawn marker is an epoch" '^[0-9]+$' \
    "$(cat "${CEKERNEL_IPC_DIR}/orchestrator.spawned")"
}

# ── conditional --bare (ADR-0016 Amendment 1) ──

@test "spawn succeeds without --bare-compatible auth, dropping --bare (OAuth)" {
  enqueue_capture
  unset ANTHROPIC_API_KEY
  run_spawn "test prompt"

  assert_eq "spawn succeeds via OAuth" "0" "$status"
  assert_match "stderr notice: bare mode disabled" "bare mode disabled" "$output"

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --bg" "--bg" "$argv"
  if [[ "$argv" == *"--bare"* ]]; then
    echo "FAIL: --bare must not appear without API-key auth: ${argv}" >&2
    return 1
  fi
  assert_match "argv keeps --plugin-dir context" "--plugin-dir" "$argv"
}
