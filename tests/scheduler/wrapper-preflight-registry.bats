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
# Note: wrapper tests cover the current (pre-#548) runner contract as-is;
# they are rewritten together with wrapper.sh in the ADR-0016 Phase 3 PR.

load '../helpers/assertions'

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
  W_REPO="/tmp/test-repo"
  W_PATH="/opt/homebrew/bin:/usr/bin:/bin"
  W_PROMPT="/dispatch --env headless --label ready"
  W_RUNNER="${CEKERNEL_VAR_DIR}/runners/${W_ID}.sh"

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

@test "wrapper: runner has set -euo pipefail and embedded PATH/CEKERNEL_DIR" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  local content
  content=$(cat "$W_RUNNER")
  assert_match "contains set -euo pipefail" "set -euo pipefail" "$content"
  assert_match "PATH is embedded" "/opt/homebrew/bin:/usr/bin:/bin" "$content"
  assert_match "CEKERNEL_DIR is embedded" "CEKERNEL_DIR=" "$content"
}

@test "wrapper: registry.sh source path in runner exists" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  local source_path
  source_path=$(grep 'source.*registry.sh' "$W_RUNNER" | sed 's/.*source "\(.*\)"/\1/' | sed "s|\${CEKERNEL_DIR}|${CEKERNEL_DIR}|")
  assert_file_exists "registry.sh source path exists" "$source_path"
}

@test "wrapper: runner uses set -e safe if/else pattern for claude -p" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  local content
  content=$(cat "$W_RUNNER")
  assert_match "uses if/else pattern" "if cd .* && claude -p" "$content"
  assert_match "has else clause" "else" "$content"
}

@test "wrapper: runner sources desktop-notify.sh and uses desktop_notify" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  local content
  content=$(cat "$W_RUNNER")
  assert_match "sources desktop-notify.sh" "desktop-notify.sh" "$content"
  assert_match "uses desktop_notify function" "desktop_notify" "$content"
}

@test "wrapper: claude output goes to <id>.run.log, syslog to schedule.log" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  local content
  content=$(cat "$W_RUNNER")
  assert_match "claude output goes to run.log" "${W_ID}.run.log" "$content"
  assert_match "syslog goes to schedule.log" "schedule.log" "$content"
  assert_match "START line format" "START" "$content"
  assert_match "END line format" "END" "$content"
  assert_match "uses SECONDS for duration" "SECONDS" "$content"
}

@test "wrapper: runner has no --max-budget-usd and no --no-session-persistence" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  run grep -E "max-budget-usd|no-session-persistence" "$W_RUNNER"
  [[ "$status" -ne 0 ]]
}

@test "wrapper: runner updates registry run status" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  assert_match "calls schedule_registry_update_status" "schedule_registry_update_status" "$(cat "$W_RUNNER")"
}

@test "wrapper: claude is invoked with explicit --bare context (ADR-0016 Phase 0)" {
  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  local content
  content=$(cat "$W_RUNNER")
  assert_match "claude invoked with --bare" "claude -p --bare" "$content"
  assert_match "plugin dir embedded" "--plugin-dir ${CEKERNEL_DIR}" "$content"
  assert_match "repo embedded as --add-dir" "--add-dir ${W_REPO}" "$content"
}

@test "wrapper: CEKERNEL_CLAUDE_SETTINGS at generation time embeds --settings" {
  # Required for cron/at: exported env vars don't reach the generated runner,
  # so auth must travel as a captured --settings path (apiKeyHelper).
  local settings_file="${CEKERNEL_VAR_DIR}/claude-settings.json"
  echo '{}' > "$settings_file"
  export CEKERNEL_CLAUDE_SETTINGS="$settings_file"

  schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  assert_match "--settings embedded in runner" "--settings ${settings_file}" "$(cat "$W_RUNNER")"
}

@test "wrapper: generation fails fast without --bare-compatible auth" {
  unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS
  run schedule_generate_wrapper "$W_ID" "$W_REPO" "$W_PATH" "$W_PROMPT"
  assert_eq "generation fails without bare auth" "1" "$status"
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
