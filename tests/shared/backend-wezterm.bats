#!/usr/bin/env bats
# backend-wezterm.bats — v2 contract tests for scripts/shared/backends/wezterm.sh
#
# ADR-0016 Phase 5: spawn delegates to the shared `claude --bg` session core
# (bg-session.sh, same path as headless); the WezTerm pane is an attach-only
# viewer running `claude attach <session-id>`. The handle is the opaque
# session token; the pane ID is a visualization detail kept in
# pane-{issue}.{type}. Pane close means detach — liveness maps to
# `claude agents --json` state, never pane existence (ADR-0001 Amendment 1).
#
# Asserts recorded argv and executed effects via PATH shims (ADR-0017) —
# never generated script text.

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
  # No surrounding WezTerm pane — workspace resolution is a no-op
  unset WEZTERM_PANE

  mock_claude
  mock_wezterm

  WORKTREE="${BATS_TEST_TMPDIR}/worktree"
  mkdir -p "$WORKTREE"
  touch "${WORKTREE}/.cekernel-env"
  WORKTREE_REAL="$(cd "$WORKTREE" && pwd -P)"

  export CEKERNEL_BACKEND=wezterm
  source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

FULL_UUID="aaaa1111-2222-4333-8444-555566667777"

# mock_wezterm — PATH shim recording argv; canned outputs per subcommand.
#   cli spawn      → pane ID 42
#   cli split-pane → pane IDs 43, 44, ... (counter file)
#   cli list       → replays ${MOCK_WEZTERM_STATE_DIR}/list.json ([] default)
mock_wezterm() {
  MOCK_WEZTERM_STATE_DIR="${BATS_TEST_TMPDIR}/mock-wezterm"
  mkdir -p "$MOCK_WEZTERM_STATE_DIR"
  export MOCK_WEZTERM_STATE_DIR

  mock_bin wezterm "STATE_DIR=\"${MOCK_WEZTERM_STATE_DIR}\"
echo \"\$*\" >> \"\$STATE_DIR/argv.log\"
if [[ \"\${1:-}\" == cli && \"\${2:-}\" == spawn ]]; then
  echo 42
elif [[ \"\${1:-}\" == cli && \"\${2:-}\" == split-pane ]]; then
  n=42
  [[ -f \"\$STATE_DIR/split-count\" ]] && n=\$(cat \"\$STATE_DIR/split-count\")
  n=\$((n + 1))
  echo \"\$n\" > \"\$STATE_DIR/split-count\"
  echo \"\$n\"
elif [[ \"\${1:-}\" == cli && \"\${2:-}\" == list ]]; then
  if [[ -f \"\$STATE_DIR/list.json\" ]]; then
    cat \"\$STATE_DIR/list.json\"
  else
    echo '[]'
  fi
fi"
}

mock_wezterm_set_list() {
  printf '%s\n' "$1" > "${MOCK_WEZTERM_STATE_DIR}/list.json"
}

# Enqueue a successful spawn capture (short ID + matching agents record)
enqueue_spawn_capture() {
  mock_claude_enqueue_short_id "aaaa1111"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"
}

# ── availability ──

@test "backend_available returns 0 when wezterm is in PATH" {
  run backend_available
  assert_eq "exit status" "0" "$status"
}

@test "backend_available returns 1 when wezterm is missing" {
  local old_path="$PATH"
  PATH=""
  local status=0
  backend_available || status=$?
  PATH="$old_path"
  assert_eq "exit status" "1" "$status"
}

# ── spawn: shared --bg session path (ADR-0016 Phase 5) ──

@test "spawn launches claude --bg with agent, bare flags, and prompt" {
  enqueue_spawn_capture

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists "bg argv recorded" "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log"
  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --bg" "--bg" "$argv"
  assert_match "argv has --agent worker" "--agent worker" "$argv"
  assert_match "argv has --bare" "--bare" "$argv"
  assert_match "argv has the prompt" "test prompt" "$argv"
}

@test "spawn does NOT use the removed -p print mode" {
  enqueue_spawn_capture

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  if [[ "$argv" =~ (^|[[:space:]])-p([[:space:]]|$) ]]; then
    echo "FAIL: -p must not appear in claude argv: ${argv}" >&2
    return 1
  fi
}

@test "spawn stores the session UUID as the handle (opaque token)" {
  enqueue_spawn_capture

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists "handle file created" "${CEKERNEL_IPC_DIR}/handle-500.worker"
  assert_eq "handle is the full UUID" "$FULL_UUID" \
    "$(cat "${CEKERNEL_IPC_DIR}/handle-500.worker")"
}

@test "spawn persists the session UUID to {type}-{issue}.claude-session-id" {
  enqueue_spawn_capture

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists "claude-session-id file created" \
    "${CEKERNEL_IPC_DIR}/worker-500.claude-session-id"
  assert_eq "persisted UUID" "$FULL_UUID" \
    "$(cat "${CEKERNEL_IPC_DIR}/worker-500.claude-session-id")"
}

@test "spawn records the pane ID separately in pane-{issue}.{type}" {
  enqueue_spawn_capture

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  assert_file_exists "pane file created" "${CEKERNEL_IPC_DIR}/pane-500.worker"
  assert_eq "pane file holds the wezterm pane ID" "42" \
    "$(cat "${CEKERNEL_IPC_DIR}/pane-500.worker")"
}

@test "spawn pane command is claude attach with the captured session UUID" {
  enqueue_spawn_capture

  backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker

  # The Lua layout payload carries the pane command
  local payload_file="${CEKERNEL_IPC_DIR}/payload-500.b64"
  assert_file_exists "payload file created" "$payload_file"
  local decoded command
  decoded=$(base64 -d < "$payload_file" 2>/dev/null || base64 -D < "$payload_file")
  command=$(echo "$decoded" | jq -r '.command')
  assert_match "pane command attaches to the session" \
    "claude attach.*${FULL_UUID}" "$command"
}

@test "spawn pane command does not run a generated -p runner or embed the prompt" {
  enqueue_spawn_capture

  backend_spawn_worker 500 worker "$WORKTREE" "secret prompt marker" worker

  local decoded command
  decoded=$(base64 -d < "${CEKERNEL_IPC_DIR}/payload-500.b64" 2>/dev/null \
    || base64 -D < "${CEKERNEL_IPC_DIR}/payload-500.b64")
  command=$(echo "$decoded" | jq -r '.command')
  if [[ "$command" == *"run-500.sh"* ]]; then
    echo "FAIL: pane command must not reference a generated runner: ${command}" >&2
    return 1
  fi
  if [[ "$command" == *"secret prompt marker"* ]]; then
    echo "FAIL: prompt must go to claude --bg, not the pane: ${command}" >&2
    return 1
  fi
}

@test "spawn fails without creating a pane when session capture fails" {
  mock_claude_enqueue_short_id "zzzzzzzz"
  # queue empty → agents --json replies [] forever → capture fails

  run backend_spawn_worker 500 worker "$WORKTREE" "test prompt" worker
  assert_eq "spawn fails" "1" "$status"
  assert_not_exists "no handle file" "${CEKERNEL_IPC_DIR}/handle-500.worker"
  if grep -q "cli spawn" "${MOCK_WEZTERM_STATE_DIR}/argv.log" 2>/dev/null; then
    echo "FAIL: no window must be spawned when the session spawn fails" >&2
    return 1
  fi
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

# ── liveness: session state, never pane existence (pane close = detach) ──

@test "backend_worker_alive returns 0 for a busy session even when the pane is gone" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  echo "42" > "${CEKERNEL_IPC_DIR}/pane-500.worker"
  # wezterm reports NO panes — the user closed the attach pane (detach)
  mock_wezterm_set_list "[]"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 busy)]"

  run backend_worker_alive 500
  assert_eq "busy session is alive despite closed pane" "0" "$status"
}

@test "backend_worker_alive returns 1 for a done session even when the pane is open" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  echo "42" > "${CEKERNEL_IPC_DIR}/pane-500.worker"
  # Pane still exists, but the session finished
  mock_wezterm_set_list '[{"pane_id": 42, "window_id": 1}]'
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 done)]"

  run backend_worker_alive 500
  assert_eq "done session is dead despite open pane" "1" "$status"
}

@test "backend_worker_alive returns 1 for a non-existent handle" {
  run backend_worker_alive 99999
  assert_eq "exit status" "1" "$status"
}

# ── status: blocked surfacing (ADR-0016) ──

@test "backend_worker_status echoes the session state" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  mock_claude_enqueue_agents \
    "[$(mock_claude_agent_record "$FULL_UUID" background "$WORKTREE_REAL" 1700000000000 blocked)]"
  run backend_worker_status 500
  assert_eq "exit status" "0" "$status"
  assert_eq "state" "blocked" "$output"
}

# ── termination: claude stop + visualization cleanup ──

@test "backend_kill_worker stops the session AND closes the window" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  echo "42" > "${CEKERNEL_IPC_DIR}/pane-500.worker"
  mock_wezterm_set_list '[{"pane_id": 42, "window_id": 1}, {"pane_id": 43, "window_id": 1}]'

  backend_kill_worker 500

  assert_file_exists "claude stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with truncated job ID (#621)" "${FULL_UUID:0:8}" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
  assert_match "window panes killed" "kill-pane" \
    "$(cat "${MOCK_WEZTERM_STATE_DIR}/argv.log")"
}

@test "backend_kill_worker cleans up pane and payload files" {
  echo "$FULL_UUID" > "${CEKERNEL_IPC_DIR}/handle-500.worker"
  echo "42" > "${CEKERNEL_IPC_DIR}/pane-500.worker"
  echo "cGF5bG9hZA==" > "${CEKERNEL_IPC_DIR}/payload-500.b64"

  backend_kill_worker 500

  assert_not_exists "pane file removed" "${CEKERNEL_IPC_DIR}/pane-500.worker"
  assert_not_exists "payload file removed" "${CEKERNEL_IPC_DIR}/payload-500.b64"
}

@test "backend_kill_worker exits cleanly for a non-existent handle" {
  run backend_kill_worker 99999
  assert_eq "exit status" "0" "$status"
}
