#!/usr/bin/env bats
# worker-stop-guard.bats — bats-core tests for scripts/hooks/worker-stop-guard.sh
#
# The guard is a Claude Code Stop hook (ADR-0018, #533). It receives the
# hook input JSON on stdin and:
#   - stays silent (exit 0, no output) for non-Worker sessions
#   - stays silent when the Worker state is TERMINATED (notify-complete.sh ran)
#   - otherwise emits hookSpecificOutput.additionalContext JSON that keeps
#     the Worker session running until the lifecycle completes
#
# Tests assert behavior (stdin → stdout/exit code) with real temp
# worktrees and state files — no mocks needed (the guard only reads files).

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GUARD="${CEKERNEL_DIR}/scripts/hooks/worker-stop-guard.sh"
  WORKTREE="${BATS_TEST_TMPDIR}/worktree"
  IPC_DIR="${BATS_TEST_TMPDIR}/ipc"
  mkdir -p "$WORKTREE" "$IPC_DIR"
}

# make_worker_worktree <issue-number>
#   Populate $WORKTREE with the files spawn.sh writes for a Worker:
#   .cekernel-task.md (issue frontmatter) and .cekernel-env (IPC dir export).
make_worker_worktree() {
  local issue="$1"
  cat > "${WORKTREE}/.cekernel-task.md" <<EOF
---
issue: ${issue}
base: main
title: "test task"
---

## Body
EOF
  cat > "${WORKTREE}/.cekernel-env" <<EOF
export CEKERNEL_SESSION_ID=test-session-00000000
export CEKERNEL_IPC_DIR=${IPC_DIR}
export CEKERNEL_ENV=default
export PATH=/usr/bin:\$PATH
EOF
}

# write_state <issue-number> <state> [detail]
#   Write a Worker state file in the same format as worker-state.sh.
write_state() {
  local issue="$1" state="$2" detail="${3:-}"
  echo "${state}:2026-07-07T00:00:00Z:${detail}" > "${IPC_DIR}/worker-${issue}.state"
}

# run_guard <input-json>
#   Run the guard with the given stdin, capturing stdout/exit code via `run`.
run_guard() {
  local input="$1"
  run bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$input" "$GUARD"
}

stop_input() {
  jq -cn --arg cwd "$WORKTREE" \
    '{cwd: $cwd, hook_event_name: "Stop", stop_hook_active: false}'
}

# ── Non-Worker sessions: guard stays silent ──

@test "silent exit for cwd without cekernel task file" {
  run_guard "$(jq -cn --arg cwd "$BATS_TEST_TMPDIR" '{cwd: $cwd, hook_event_name: "Stop"}')"
  assert_eq "exit code" "0" "$status"
  assert_eq "no output" "" "$output"
}

@test "silent exit for task file without cekernel-env" {
  make_worker_worktree 42
  rm "${WORKTREE}/.cekernel-env"
  run_guard "$(stop_input)"
  assert_eq "exit code" "0" "$status"
  assert_eq "no output" "" "$output"
}

@test "silent exit for task file without a parsable issue number" {
  make_worker_worktree 42
  printf -- '---\ntitle: "no issue field"\n---\n' > "${WORKTREE}/.cekernel-task.md"
  run_guard "$(stop_input)"
  assert_eq "exit code" "0" "$status"
  assert_eq "no output" "" "$output"
}

@test "silent exit on invalid JSON input (fail-open, never breaks a session)" {
  run_guard "not json at all"
  assert_eq "exit code" "0" "$status"
  assert_eq "no output" "" "$output"
}

@test "silent exit on empty cwd" {
  run_guard '{"hook_event_name": "Stop"}'
  assert_eq "exit code" "0" "$status"
  assert_eq "no output" "" "$output"
}

# ── Completed lifecycle: stop is allowed ──

@test "silent exit when worker state is TERMINATED" {
  make_worker_worktree 42
  write_state 42 TERMINATED "ci-passed"
  run_guard "$(stop_input)"
  assert_eq "exit code" "0" "$status"
  assert_eq "no output" "" "$output"
}

# ── Incomplete lifecycle: guard emits additionalContext ──

@test "emits additionalContext when worker state is RUNNING" {
  make_worker_worktree 42
  write_state 42 RUNNING "phase1:implement"
  run_guard "$(stop_input)"
  assert_eq "exit code" "0" "$status"
  local context
  context=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  assert_match "context names the issue" "#42" "$context"
  assert_match "context names the state" "RUNNING" "$context"
  assert_match "context points to notify-complete" "notify-complete.sh" "$context"
  assert_eq "hookEventName echoes input event" "Stop" \
    "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
}

@test "emits additionalContext when worker state is WAITING with detail" {
  make_worker_worktree 7
  write_state 7 WAITING "phase3:ci-waiting"
  run_guard "$(stop_input | jq -c '.')"
  assert_eq "exit code" "0" "$status"
  local context
  context=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
  assert_match "context names the issue" "#7" "$context"
  assert_match "context carries the phase detail" "phase3:ci-waiting" "$context"
}

@test "emits additionalContext with UNKNOWN state when no state file exists" {
  make_worker_worktree 42
  run_guard "$(stop_input)"
  assert_eq "exit code" "0" "$status"
  assert_match "context reports UNKNOWN state" "UNKNOWN" \
    "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
}

@test "hookEventName echoes SubagentStop when the input event is SubagentStop" {
  make_worker_worktree 42
  write_state 42 RUNNING "phase1:implement"
  run_guard "$(jq -cn --arg cwd "$WORKTREE" \
    '{cwd: $cwd, hook_event_name: "SubagentStop", stop_hook_active: false}')"
  assert_eq "exit code" "0" "$status"
  assert_eq "hookEventName" "SubagentStop" \
    "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
}

# ── Kill switch ──

@test "CEKERNEL_DISABLE_STOP_GUARD=1 disables the guard" {
  make_worker_worktree 42
  write_state 42 RUNNING "phase1:implement"
  local input
  input="$(stop_input)"
  run bash -c "printf '%s' \"\$1\" | CEKERNEL_DISABLE_STOP_GUARD=1 bash \"\$2\"" _ "$input" "$GUARD"
  assert_eq "exit code" "0" "$status"
  assert_eq "no output" "" "$output"
}

# ── Plugin wiring: hooks.json points at the guard ──
# The change ships an executable script; this config assertion is a
# regression guard so a broken hooks.json cannot silently disable the
# guard (Rule of Repair).

@test "plugin hooks.json registers the guard as a Stop hook" {
  local hooks_json="${CEKERNEL_DIR}/hooks/hooks.json"
  assert_file_exists "hooks.json" "$hooks_json"
  run jq -r '.hooks.Stop[0].hooks[0].command' "$hooks_json"
  assert_eq "jq parses hooks.json" "0" "$status"
  assert_match "command references the guard script" "worker-stop-guard.sh" "$output"
  [[ -x "${CEKERNEL_DIR}/scripts/hooks/worker-stop-guard.sh" ]] || {
    echo "FAIL: guard script missing or not executable" >&2
    return 1
  }
}
