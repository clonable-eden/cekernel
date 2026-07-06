#!/usr/bin/env bats
# wrapper-preflight-registry.bats — bats-core tests for the scheduler support
# scripts (ADR-0017 Decision 4: wrapper + preflight + registry merged).
#
# Subjects:
#   - scripts/scheduler/wrapper.sh   (schedule_generate_wrapper)
#   - scripts/scheduler/preflight.sh (schedule_preflight_check)
#   - scripts/scheduler/registry.sh  (schedule_registry_* CRUD)
# Consolidates legacy tests/scheduler/test-wrapper.sh, test-preflight.sh,
# and test-registry.sh.
#
# Wrapper tests cover the ADR-0016 Phase 3 runner contract: the generated
# runner spawns `claude --bg` and polls agents --json to a terminal state.
# They EXECUTE the generated runner against the canonical mock-claude shim
# and assert executed effects and recorded argv — never generated script
# text (ADR-0017).

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  export CEKERNEL_VAR_DIR="${BATS_TEST_TMPDIR}/var"
  mkdir -p "${CEKERNEL_VAR_DIR}/runners" "${CEKERNEL_VAR_DIR}/logs"
  echo '[]' > "${CEKERNEL_VAR_DIR}/schedules.json"

  # --bare preflight requires an auth path (never reads OAuth/keychain)
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS

  source "${CEKERNEL_DIR}/scripts/scheduler/wrapper.sh"
  source "${CEKERNEL_DIR}/scripts/scheduler/preflight.sh"
  source "${CEKERNEL_DIR}/scripts/scheduler/registry.sh"

  # ── wrapper fixtures ──
  W_ID="cekernel-cron-test01"
  W_REPO="${BATS_TEST_TMPDIR}/test-repo"
  W_PATH="/opt/homebrew/bin:/usr/bin:/bin"
  W_PROMPT="/dispatch --env headless --label ready"
  W_RUNNER="${CEKERNEL_VAR_DIR}/runners/${W_ID}.sh"
  W_SYSLOG="${CEKERNEL_VAR_DIR}/logs/schedule.log"
  W_RUN_LOG="${CEKERNEL_VAR_DIR}/logs/${W_ID}.run.log"
  W_UUID="aaaa1111-2222-4333-8444-555566667777"

  # ── preflight fixtures: fake repo + PATH-shim bin dir ──
  # TEST_BIN is used both prepended (all commands found) and as a full PATH
  # replacement (commands missing), so it is managed directly rather than
  # via mock_bin (which only prepends).
  TEST_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${TEST_REPO}/.claude"
  echo '{"permissions":{"allow":["Bash","Read"]}}' > "${TEST_REPO}/.claude/settings.json"

  TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$TEST_BIN"
  local cmd
  for cmd in claude gh git; do
    echo '#!/bin/bash' > "${TEST_BIN}/${cmd}"
    chmod +x "${TEST_BIN}/${cmd}"
  done

  # Absolute bash path: preflight tests replace PATH entirely
  BASH_BIN="$(command -v bash)"

  # ── registry fixtures ──
  SAMPLE_ENTRY='{"id":"cekernel-cron-abc123","type":"cron","schedule":"0 9 * * 1-5","label":"ready","repo":"/tmp/test-repo","path":"/usr/bin:/bin","os_backend":"launchd","os_ref":"cekernel-cron-abc123","created_at":"2026-03-01T10:00:00Z","last_run_at":null,"last_run_status":null}'
  SAMPLE_AT_ENTRY='{"id":"cekernel-at-def456","type":"at","schedule":"2026-03-15T09:00","label":"deploy","repo":"/tmp/test-repo","path":"/usr/bin:/bin","os_backend":"launchd","os_ref":"cekernel-at-def456","created_at":"2026-03-01T11:00:00Z","last_run_at":null,"last_run_status":null}'
}

# Run schedule_preflight_check in a fresh bash with a controlled PATH.
preflight_with_path() {
  local path_value="$1" type="$2" repo="$3"
  run env PATH="$path_value" "$BASH_BIN" -c \
    "source '${CEKERNEL_DIR}/scripts/scheduler/preflight.sh'; schedule_preflight_check '$type' '$repo'"
}

# ═══════════════════════════════════════
# wrapper.sh — schedule_generate_wrapper
# ═══════════════════════════════════════

# generate_exec_runner [poll-interval] [poll-timeout]
# Prepares an executable runner: installs the claude shim + notification
# no-ops (desktop_notify is best-effort but must not fire real OS
# notifications from tests), registers a registry entry for W_ID, and
# generates the runner with the shim dir on its embedded PATH (cron
# runners only see the PATH captured at schedule time).
generate_exec_runner() {
  local interval="${1:-0}" timeout="${2:-5}"
  mock_claude
  mock_bin alerter ':'
  mock_bin osascript ':'
  mock_bin notify-send ':'
  mkdir -p "$W_REPO"
  schedule_registry_add "{\"id\":\"${W_ID}\",\"type\":\"cron\",\"schedule\":\"0 9 * * *\",\"label\":\"ready\",\"repo\":\"${W_REPO}\",\"path\":\"${PATH}\",\"os_backend\":\"launchd\",\"os_ref\":\"${W_ID}\",\"created_at\":\"2026-03-01T10:00:00Z\",\"last_run_at\":null,\"last_run_status\":null}"
  CEKERNEL_SCHEDULE_POLL_INTERVAL="$interval" \
    CEKERNEL_SCHEDULE_POLL_TIMEOUT="$timeout" \
    schedule_generate_wrapper "$W_ID" "$W_REPO" "$PATH" "$W_PROMPT"
}

# enqueue_session <state...>
# Queues the short ID plus one agents --json response per given state,
# all for W_UUID at the runner repo cwd (realpath'd, as the real CLI
# reports). The last response repeats forever (mock-claude contract),
# so ending with a non-terminal state scripts the timeout branch.
enqueue_session() {
  local repo_real state
  repo_real="$(cd "$W_REPO" && pwd -P)"
  mock_claude_enqueue_short_id "aaaa1111"
  for state in "$@"; do
    mock_claude_enqueue_agents \
      "[$(mock_claude_agent_record "$W_UUID" background "$repo_real" 1700000000000 "$state")]"
  done
}

@test "wrapper: generated runner exists with 700 permissions" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  assert_file_exists "wrapper file exists" "$W_RUNNER"

  local perms
  if [[ "$(uname)" == "Darwin" ]]; then
    perms=$(stat -f '%Lp' "$W_RUNNER")
  else
    perms=$(stat -c '%a' "$W_RUNNER")
  fi
  assert_eq "wrapper has 700 permissions" "700" "$perms"
}

@test "wrapper: generation fails fast without --bare-compatible auth" {
  unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS
  run schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  assert_eq "generation fails without bare auth" "1" "$status"
}

@test "wrapper: runner spawns claude --bg with bare context and prompt (argv contract)" {
  generate_exec_runner
  enqueue_session busy done

  run "$W_RUNNER"
  assert_eq "runner exits 0 when the session reaches done" "0" "$status"

  assert_file_exists "bg argv recorded" "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log"
  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  assert_match "argv has --bg" "--bg" "$argv"
  assert_match "argv has --bare" "--bare" "$argv"
  assert_match "argv has --plugin-dir" "--plugin-dir ${CEKERNEL_DIR}" "$argv"
  assert_match "argv has --add-dir repo" "--add-dir ${W_REPO}" "$argv"
  assert_match "argv has the prompt" "$W_PROMPT" "$argv"
}

@test "wrapper: runner does NOT use the removed -p print mode" {
  generate_exec_runner
  enqueue_session done

  run "$W_RUNNER"

  local argv
  argv=$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")
  if [[ "$argv" =~ (^|[[:space:]])-p([[:space:]]|$) ]]; then
    echo "FAIL: -p must not appear in claude argv: ${argv}" >&2
    return 1
  fi
}

@test "wrapper: done session → registry success, syslog START/END, spawn line in run.log" {
  generate_exec_runner
  enqueue_session busy done

  run "$W_RUNNER"
  assert_eq "runner exits 0" "0" "$status"

  assert_eq "registry records success" "success" \
    "$(schedule_registry_get "$W_ID" | jq -r '.last_run_status')"
  assert_match "last_run_at is an ISO timestamp" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" \
    "$(schedule_registry_get "$W_ID" | jq -r '.last_run_at')"

  local syslog
  syslog=$(cat "$W_SYSLOG")
  assert_match "START line written" "cekernel\[${W_ID}\]: START" "$syslog"
  assert_match "END line records success + final state" \
    "END status=success state=done" "$syslog"
  assert_match "END line records the poll-window duration" "duration=" "$syslog"

  assert_match "spawn line captured in run.log" "backgrounded" "$(cat "$W_RUN_LOG")"
}

@test "wrapper: runner reaps the done session via claude stop" {
  generate_exec_runner
  enqueue_session busy done

  run "$W_RUNNER"

  assert_file_exists "stop recorded" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
  assert_eq "stop called with the captured token" "$W_UUID" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
}

@test "wrapper: blocked session → registry error, exit 1, session stopped" {
  generate_exec_runner
  enqueue_session blocked

  run "$W_RUNNER"
  assert_eq "runner exits 1 on blocked" "1" "$status"

  assert_eq "registry records error" "error" \
    "$(schedule_registry_get "$W_ID" | jq -r '.last_run_status')"
  assert_match "END line records the blocked state" \
    "END status=error state=blocked" "$(cat "$W_SYSLOG")"
  # blocked never unblocks unattended — the session must be reaped
  assert_eq "blocked session stopped" "$W_UUID" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/stop.log")"
}

@test "wrapper: poll timeout → registry error, session left running (no stop)" {
  generate_exec_runner 1 1
  # Non-terminating sequence: the session never leaves busy (ADR-0017)
  enqueue_session busy

  run "$W_RUNNER"
  assert_eq "runner exits 1 on timeout" "1" "$status"

  assert_eq "registry records error" "error" \
    "$(schedule_registry_get "$W_ID" | jq -r '.last_run_status')"
  assert_match "END line records the timeout" \
    "END status=error state=timeout" "$(cat "$W_SYSLOG")"
  # On timeout the session may still be doing real work — never kill it
  assert_not_exists "no stop call on timeout" "${MOCK_CLAUDE_STATE_DIR}/stop.log"
}

@test "wrapper: spawn failure → registry error, exit 1" {
  generate_exec_runner
  # Replace the claude shim with a failing one AFTER generation
  mock_bin claude 'exit 1'

  run "$W_RUNNER"
  assert_eq "runner exits 1 on spawn failure" "1" "$status"

  assert_eq "registry records error" "error" \
    "$(schedule_registry_get "$W_ID" | jq -r '.last_run_status')"
  assert_match "END line records the spawn failure" \
    "END status=error state=spawn-failed" "$(cat "$W_SYSLOG")"
}

@test "wrapper: session-ID capture failure → registry error, exit 1" {
  generate_exec_runner
  # Non-hex short ID rejects the stdout parse; agents --json stays [] —
  # neither capture path resolves
  mock_claude_enqueue_short_id "zzzzzzzz"

  run "$W_RUNNER"
  assert_eq "runner exits 1 on capture failure" "1" "$status"

  assert_eq "registry records error" "error" \
    "$(schedule_registry_get "$W_ID" | jq -r '.last_run_status')"
  assert_match "END line records the capture failure" \
    "END status=error state=capture-failed" "$(cat "$W_SYSLOG")"
}

@test "wrapper: CEKERNEL_CLAUDE_SETTINGS at generation time reaches claude argv" {
  # Required for cron/at: exported env vars don't reach the generated runner,
  # so auth must travel as a captured --settings path (apiKeyHelper).
  local settings_file="${CEKERNEL_VAR_DIR}/claude-settings.json"
  echo '{}' > "$settings_file"
  export CEKERNEL_CLAUDE_SETTINGS="$settings_file"

  generate_exec_runner
  enqueue_session done

  run "$W_RUNNER"

  assert_match "--settings passed to claude" "--settings ${settings_file}" \
    "$(cat "${MOCK_CLAUDE_STATE_DIR}/bg-argv.log")"
}

# ═══════════════════════════════════════
# preflight.sh — schedule_preflight_check
# ═══════════════════════════════════════

@test "preflight: all checks pass with valid setup" {
  preflight_with_path "${TEST_BIN}:${PATH}" cron "$TEST_REPO"
  assert_eq "preflight passes with valid setup" "0" "$status"
}

@test "preflight: fails when claude is not found" {
  rm "${TEST_BIN}/claude"
  preflight_with_path "$TEST_BIN" cron "$TEST_REPO"
  [[ "$status" -ne 0 ]]
}

@test "preflight: fails when gh is not found" {
  rm "${TEST_BIN}/gh"
  preflight_with_path "$TEST_BIN" cron "$TEST_REPO"
  [[ "$status" -ne 0 ]]
}

@test "preflight: fails when git is not found" {
  rm "${TEST_BIN}/git"
  preflight_with_path "$TEST_BIN" cron "$TEST_REPO"
  [[ "$status" -ne 0 ]]
}

@test "preflight: fails when .claude/settings.json is missing" {
  rm "${TEST_REPO}/.claude/settings.json"
  preflight_with_path "${TEST_BIN}:${PATH}" cron "$TEST_REPO"
  [[ "$status" -ne 0 ]]
}

@test "preflight: multiple failures are all reported (no early exit)" {
  rm "${TEST_BIN}/claude"
  rm "${TEST_REPO}/.claude/settings.json"
  preflight_with_path "$TEST_BIN" cron "$TEST_REPO"
  [[ "$status" -ne 0 ]]

  local fail_count
  fail_count=$(echo "$output" | grep -c "FAIL" || true)
  # claude + settings.json = at least 2 FAILs
  [[ "$fail_count" -ge 2 ]]
}

@test "preflight: type=cron does not check atd" {
  preflight_with_path "${TEST_BIN}:${PATH}" cron "$TEST_REPO"
  run grep "atd" <<<"$output"
  [[ "$status" -ne 0 ]]
}

@test "preflight: type=at on Linux checks atd" {
  [[ "$(uname)" == "Darwin" ]] && skip "atd check only applies on Linux"
  preflight_with_path "${TEST_BIN}:${PATH}" at "$TEST_REPO"
  assert_match "at type on Linux mentions atd" "atd" "$output"
}

# ═══════════════════════════════════════
# registry.sh — schedule_registry_* CRUD
# ═══════════════════════════════════════

@test "registry: list on empty registry returns empty array" {
  assert_eq "list on empty registry returns []" "[]" "$(schedule_registry_list)"
}

@test "registry: add entry then list returns it" {
  schedule_registry_add "$SAMPLE_ENTRY"
  assert_eq "add then list has 1 entry" "1" "$(schedule_registry_list | jq length)"
  assert_eq "added entry has correct id" "cekernel-cron-abc123" "$(schedule_registry_list | jq -r '.[0].id')"
}

@test "registry: add duplicate ID fails and does not add a second entry" {
  schedule_registry_add "$SAMPLE_ENTRY"
  run schedule_registry_add "$SAMPLE_ENTRY"
  [[ "$status" -ne 0 ]]
  assert_eq "duplicate ID does not add second entry" "1" "$(schedule_registry_list | jq length)"
}

@test "registry: add multiple entries" {
  schedule_registry_add "$SAMPLE_ENTRY"
  schedule_registry_add "$SAMPLE_AT_ENTRY"
  assert_eq "add two entries, list has 2" "2" "$(schedule_registry_list | jq length)"
}

@test "registry: list --type cron filters correctly" {
  schedule_registry_add "$SAMPLE_ENTRY"
  schedule_registry_add "$SAMPLE_AT_ENTRY"
  assert_eq "list --type cron returns 1" "1" "$(schedule_registry_list --type cron | jq length)"
  assert_eq "list --type cron returns cron entry" "cron" "$(schedule_registry_list --type cron | jq -r '.[0].type')"
}

@test "registry: list --type at filters correctly" {
  schedule_registry_add "$SAMPLE_ENTRY"
  schedule_registry_add "$SAMPLE_AT_ENTRY"
  assert_eq "list --type at returns 1" "1" "$(schedule_registry_list --type at | jq length)"
  assert_eq "list --type at returns at entry" "at" "$(schedule_registry_list --type at | jq -r '.[0].type')"
}

@test "registry: get existing entry" {
  schedule_registry_add "$SAMPLE_ENTRY"
  assert_eq "get returns correct entry" "cekernel-cron-abc123" \
    "$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.id')"
}

@test "registry: get non-existing entry returns exit 1" {
  run schedule_registry_get "nonexistent"
  [[ "$status" -ne 0 ]]
}

@test "registry: remove existing entry keeps the others" {
  schedule_registry_add "$SAMPLE_ENTRY"
  schedule_registry_add "$SAMPLE_AT_ENTRY"
  schedule_registry_remove "cekernel-cron-abc123"
  assert_eq "remove leaves 1 entry" "1" "$(schedule_registry_list | jq length)"
  assert_eq "remaining entry is the at entry" "cekernel-at-def456" "$(schedule_registry_list | jq -r '.[0].id')"
}

@test "registry: remove non-existing entry is idempotent" {
  schedule_registry_remove "nonexistent"
  assert_eq "remove nonexistent is idempotent" "0" "$(schedule_registry_list | jq length)"
}

@test "registry: update_status sets last_run_status" {
  schedule_registry_add "$SAMPLE_ENTRY"
  schedule_registry_update_status "cekernel-cron-abc123" "success"
  assert_eq "update_status sets success" "success" \
    "$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.last_run_status')"
}

@test "registry: update_status sets last_run_at timestamp" {
  schedule_registry_add "$SAMPLE_ENTRY"
  schedule_registry_update_status "cekernel-cron-abc123" "error"
  assert_match "update_status sets last_run_at to ISO timestamp" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" \
    "$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.last_run_at')"
  assert_eq "update_status sets error" "error" \
    "$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.last_run_status')"
}

@test "registry: add fails when lock is held (lock timeout)" {
  mkdir "${CEKERNEL_VAR_DIR}/schedules.json.lock"
  run schedule_registry_add "$SAMPLE_ENTRY"
  [[ "$status" -ne 0 ]]
}
