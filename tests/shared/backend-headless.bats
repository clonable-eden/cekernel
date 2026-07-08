#!/usr/bin/env bats
# backend-headless.bats — v2 contract tests for scripts/shared/backends/headless.sh
#
# ADR-0016 Phase 1: spawn delegates to `claude --bg --agent`; the handle is
# an opaque session token (full UUID, short ID as degraded fallback);
# liveness/status map to `claude agents --json` state; termination maps to
# `claude stop`. Asserts recorded argv and executed effects via the
# canonical mock-claude shim (ADR-0017) — never generated script text.
#
# Since ADR-0016 Phase 5, headless.sh is a thin delegation to the shared
# session core (scripts/shared/bg-session.sh) — this suite doubles as the
# contract coverage for that core (wezterm/tmux reuse it for spawn).

load '../helpers/assertions'
load '../helpers/session'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"

  # --bare preflight requires an explicit auth path
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL

  mock_claude

  # Worktree with the .cekernel-env file spawn sources (always present in prod)
  WORKTREE="${BATS_TEST_TMPDIR}/worktree"
  mkdir -p "$WORKTREE"
  touch "${WORKTREE}/.cekernel-env"
  # agents --json reports realpath'd cwd (verified v2.1.201: /tmp → /private/tmp)
  WORKTREE_REAL="$(cd "$WORKTREE" && pwd -P)"

  export CEKERNEL_BACKEND=headless
  source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

FULL_UUID="aaaa1111-2222-4333-8444-555566667777"

# ── availability ──

@test "backend_available returns 0 (headless always available)" {
  run backend_available
  assert_eq "exit status" "0" "$status"
}

# ── spawn: --bg argv contract ──

@test "spawn launches claude --bg with agent, bare flags, and prompt" {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists "bg argv recorded" "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log"
  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --bg" "--bg" "$argv"
  assert_match "argv has --agent worker" "--agent worker" "$argv"
  assert_match "argv has --bare" "--bare" "$argv"
  assert_match "argv has the prompt" "test prompt" "$argv"
}

@test "spawn passes a plugin-scoped agent name from the 5th parameter" {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" "cekernel:worker"

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --agent cekernel:worker" "--agent cekernel:worker" "$argv"
}

@test "spawn does NOT use the removed -p print mode" {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  if [[ "$argv" =~ (^|[[:space:]])-p([[:space:]]|$) ]]; then
    echo "FAIL: -p must not appear in claude argv: ${argv}" >&2
    return 1
  fi
}

# ── spawn: session-ID capture (ADR-0016 normative order) ──

@test "spawn captures the full session UUID via short-ID prefix match" {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists "handle file created" "${CEKERNEL_IPC_DIR}/handle-500.worker"
  assert_eq "handle is the full UUID" "$FULL_UUID" \
    "$(cat "${CEKERNEL_IPC_DIR}/handle-500.worker")"
}

@test "spawn persists the session UUID to {type}-{issue}.claude-session-id" {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists "claude-session-id file created" \
    "${CEKERNEL_IPC_DIR}/worker-500.claude-session-id"
  assert_eq "persisted UUID" "$FULL_UUID" \
    "$(cat "${CEKERNEL_IPC_DIR}/worker-500.claude-session-id")"
}

@test "spawn falls back to kind+cwd+startedAt when stdout parse fails" {
  # Non-hex short ID → stdout parse rejects it → fallback path
  mock_claude_enqueue_short_id "zzzzzzzz"
  # Interactive session at the same cwd with a NEWER startedAt must NOT match
  # (the kind filter is mandatory — regression from ADR-0016)
  mock_claude_enqueue_agents "[
    $(mock_claude_agent_record "bbbb0000-1111-4222-8333-444455556666" interactive "$WORKTREE_REAL" 1700000099000 busy),
    $(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy),
    $(mock_claude_agent_record "cccc0000-1111-4222-8333-444455556666" background "$WORKTREE_REAL" 1699999999000 busy)
  ]"

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_eq "handle is the newest background session at the worktree cwd" \
    "$FULL_UUID" "$(cat "${CEKERNEL_IPC_DIR}/handle-500.worker")"
}

@test "spawn degrades to the short ID when agents --json has no match" {
  # Default queue: short ID "deadbeef", agents --json replies []
  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_eq "handle degrades to the short ID" "deadbeef" \
    "$(cat "${CEKERNEL_IPC_DIR}/handle-500.worker")"
}

@test "spawn fails when neither short ID nor cwd fallback resolves" {
  mock_claude_enqueue_short_id "zzzzzzzz"
  # queue empty → agents --json replies [] forever

  run backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker
  assert_eq "spawn fails" "1" "$status"
  assert_not_exists "no handle file on capture failure" \
    "${CEKERNEL_IPC_DIR}/handle-500.worker"
}

@test "spawn sources .cekernel-env from the worktree" {
  local marker="${BATS_TEST_TMPDIR}/env-sourced.marker"
  echo "touch '${marker}'" > "${WORKTREE}/.cekernel-env"
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists ".cekernel-env sourced" "$marker"
}

# ADR-0016 Amendment 1 (#574): without a bare-compatible auth path the spawn
# still succeeds — --bare is dropped so the session authenticates via
# OAuth/keychain. Only scheduled paths (wrapper.sh) keep the hard fail.
@test "spawn succeeds without --bare-compatible auth, dropping --bare (OAuth)" {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  run bash -c "
    unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS
    source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh'
    backend_spawn_worker 505 worker '$WORKTREE' 'test prompt' worker
  "
  assert_eq "spawn succeeds via OAuth" "0" "$status"
  assert_match "stderr notice: bare mode disabled" "bare mode disabled" "$output"
  assert_file_exists "handle file written" \
    "${CEKERNEL_IPC_DIR}/handle-505.worker"

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --bg" "--bg" "$argv"
  if [[ "$argv" == *"--bare"* ]]; then
    echo "FAIL: --bare must not appear without API-key auth: ${argv}" >&2
    return 1
  fi
  assert_match "argv keeps --plugin-dir context" "--plugin-dir" "$argv"
}

# ── handle accessor ──

@test "backend_get_handle returns the opaque session token" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  run backend_get_handle 500 worker
  assert_eq "exit status" "0" "$status"
  assert_eq "token" "$FULL_UUID" "$output"
}

@test "backend_get_handle fails for a non-existent handle" {
  run backend_get_handle 99999 worker
  assert_eq "exit status" "1" "$status"
}

# ── liveness: agents --json state ──

@test "backend_worker_alive returns 0 for a busy session" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"
  run backend_worker_alive 500
  assert_eq "busy session is alive" "0" "$status"
}

@test "backend_worker_alive returns 0 for a blocked session (alive but stalled)" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 blocked)]"
  run backend_worker_alive 500
  assert_eq "blocked session is alive" "0" "$status"
}

@test "backend_worker_alive returns 1 for a done session" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 done)]"
  run backend_worker_alive 500
  assert_eq "done session is dead" "1" "$status"
}

@test "backend_worker_alive returns 1 when the session is not listed" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  # queue empty → []
  run backend_worker_alive 500
  assert_eq "missing session is dead" "1" "$status"
}

@test "backend_worker_alive returns 1 for a non-existent handle" {
  run backend_worker_alive 99999
  assert_eq "exit status" "1" "$status"
}

@test "backend_worker_alive prefix-matches a short-ID handle (degraded capture)" {
  echo "aaaa1111" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"
  run backend_worker_alive 500
  assert_eq "short-ID handle matches by prefix" "0" "$status"
}

# ── status: ADR-0018 verdict vocabulary (blocked surfacing, ADR-0016) ──

@test "backend_worker_status echoes the alive verdict for a busy session" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"
  run backend_worker_status 500
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "alive" "$output"
}

@test "backend_worker_status echoes the blocked verdict distinctly" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 blocked)]"
  run backend_worker_status 500
  assert_eq "exit status" "0" "$status"
  assert_eq "verdict" "blocked" "$output"
}

@test "backend_worker_status echoes not-listed when the session is absent" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  run backend_worker_status 500
  assert_eq "exit status" "3" "$status"
  assert_eq "report" "not-listed" "$output"
}

@test "backend_worker_status echoes missing and fails for a non-existent handle" {
  run backend_worker_status 99999
  assert_eq "exit status" "1" "$status"
  assert_eq "report" "missing" "$output"
}

@test "backend_worker_status echoes query-failed when the agents query fails (transient)" {
  # A failed `claude agents --json` (daemon restarting) must be
  # distinguishable from a session verifiably not listed — supervision
  # must not treat the former as a crash (#573, ADR-0018).
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_bin claude 'exit 1'
  run backend_worker_status 500
  assert_eq "exit status" "4" "$status"
  assert_eq "report" "query-failed" "$output"
}

@test "backend_worker_status propagates unknown-value (never coerced)" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record_pair "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 idle working)]"
  run --separate-stderr backend_worker_status 500
  assert_eq "exit status" "5" "$status"
  assert_eq "report" "unknown-value" "$output"
}

# ── termination: claude stop ──

@test "backend_kill_worker stops the session via claude stop" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  backend_kill_worker 500
  assert_file_exists "stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with the token" "$FULL_UUID" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
}

@test "backend_kill_worker with type stops only that handle" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  echo "bbbb0000-1111-4222-8333-444455556666" > "${CEKERNEL_IPC_DIR}/handle-500.reviewer"
  backend_kill_worker 500 worker
  assert_eq "only the worker token stopped" "$FULL_UUID" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
}

@test "backend_kill_worker without type stops all handles for the issue" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  echo "bbbb0000-1111-4222-8333-444455556666" > "${CEKERNEL_IPC_DIR}/handle-500.reviewer"
  backend_kill_worker 500
  local stopped
  stopped=$(sort "${MOCK_CLAUDE_STATE_DIR}/stop.log")
  assert_match "worker token stopped" "$FULL_UUID" "$stopped"
  assert_match "reviewer token stopped" "bbbb0000-1111-4222-8333-444455556666" "$stopped"
}

@test "backend_kill_worker exits cleanly for a non-existent handle" {
  run backend_kill_worker 99999
  assert_eq "exit status" "0" "$status"
  assert_not_exists "no stop call" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
}
