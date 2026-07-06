#!/usr/bin/env bats
# cron.bats — bats-core tests for scripts/scheduler/cron.sh (ADR-0017 Decision 4)
#
# CLI contract of the /cron skill backend: register / list / cancel.
# Consolidates legacy tests/scheduler/test-cron.sh.
#
# OS scheduler side effects are isolated via PATH shims (mock_bin) on macOS
# (launchctl) and via the _CRON_CRONTAB_FILE test hook on Linux.

load '../helpers/assertions'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CRON_SH="${CEKERNEL_DIR}/scripts/scheduler/cron.sh"

  export CEKERNEL_VAR_DIR="${BATS_TEST_TMPDIR}/var"
  mkdir -p "${CEKERNEL_VAR_DIR}/runners" "${CEKERNEL_VAR_DIR}/logs"
  echo '[]' > "${CEKERNEL_VAR_DIR}/schedules.json"

  # --bare preflight requires an auth path (never reads OAuth/keychain)
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS

  # Repo with .claude/settings.json (preflight requirement)
  MOCK_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${MOCK_REPO}/.claude"
  echo '{"permissions":{"allow":["Bash"]}}' > "${MOCK_REPO}/.claude/settings.json"

  # launchd dir for the macOS backend
  export CEKERNEL_LAUNCHD_DIR="${BATS_TEST_TMPDIR}/launchd"
  mkdir -p "$CEKERNEL_LAUNCHD_DIR"

  # crontab file hook for the Linux backend (no real crontab writes)
  export _CRON_CRONTAB_FILE="${BATS_TEST_TMPDIR}/crontab"
  echo "" > "$_CRON_CRONTAB_FILE"

  # Preflight presence checks — never invoked for real in these tests
  mock_bin claude ':'
  mock_bin gh ':'
  mock_bin git ':'
  mock_bin crontab ':'
  # macOS backend: no real launchd side effects
  mock_bin launchctl ':'
}

# ═══════════════════════════════════════
# register
# ═══════════════════════════════════════

@test "cron.sh register adds registry entry and creates runner" {
  run bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "register adds registry entry" "1" "$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")"

  local runner_id
  runner_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  assert_file_exists "runner script created" "${CEKERNEL_VAR_DIR}/runners/${runner_id}.sh"
}

@test "cron.sh register output contains ID and details" {
  run bash "$CRON_SH" register --label deploy --schedule "30 */6 * * *" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_match "output contains Registered" "Registered:" "$output"
  assert_match "output contains Schedule" "30 \*/6 \* \* \*" "$output"
  assert_match "output contains Label" "deploy" "$output"
}

@test "cron.sh register without --label or --prompt fails" {
  run bash "$CRON_SH" register --schedule "0 9 * * *" --repo "$MOCK_REPO"
  [[ "$status" -ne 0 ]]
}

@test "cron.sh register without --schedule fails" {
  run bash "$CRON_SH" register --label ready --repo "$MOCK_REPO"
  [[ "$status" -ne 0 ]]
}

@test "cron.sh register with --prompt succeeds" {
  run bash "$CRON_SH" register --prompt "run my custom task" --schedule "0 9 * * 1-5" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "register with --prompt adds entry" "1" "$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")"
  assert_match "output contains Prompt" "run my custom task" "$output"
}

@test "cron.sh --prompt takes precedence over --label" {
  run bash "$CRON_SH" register --label ready --prompt "custom prompt" --schedule "0 9 * * 1-5" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "prompt field has --prompt value" "custom prompt" \
    "$(jq -r '.[0].prompt' "${CEKERNEL_VAR_DIR}/schedules.json")"
}

@test "cron.sh --label generates dispatch prompt in registry" {
  run bash "$CRON_SH" register --label deploy --schedule "0 9 * * 1-5" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "label generates dispatch prompt" "/dispatch --env headless --label deploy" \
    "$(jq -r '.[0].prompt' "${CEKERNEL_VAR_DIR}/schedules.json")"
}

@test "cron.sh registry entry has correct schema" {
  run bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"

  local entry
  entry=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
  assert_eq "entry type is cron" "cron" "$(echo "$entry" | jq -r '.type')"
  assert_eq "entry label is ready" "ready" "$(echo "$entry" | jq -r '.label')"
  assert_eq "entry schedule is correct" "0 9 * * 1-5" "$(echo "$entry" | jq -r '.schedule')"
  assert_match "entry id starts with cekernel-cron-" "^cekernel-cron-" "$(echo "$entry" | jq -r '.id')"
  assert_match "entry created_at is ISO timestamp" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$(echo "$entry" | jq -r '.created_at')"
}

# ═══════════════════════════════════════
# list
# ═══════════════════════════════════════

@test "cron.sh list with no entries shows message" {
  run bash "$CRON_SH" list
  assert_eq "list exits 0" "0" "$status"
  assert_match "list shows no schedules message" "No cron schedules registered" "$output"
}

@test "cron.sh list after register shows entry" {
  bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1

  local entry_id
  entry_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  run bash "$CRON_SH" list
  assert_eq "list exits 0" "0" "$status"
  assert_match "list shows registered ID" "$entry_id" "$output"
  assert_match "list shows schedule" "0 9" "$output"
  assert_match "list shows label" "ready" "$output"
}

# ═══════════════════════════════════════
# cancel
# ═══════════════════════════════════════

@test "cron.sh cancel removes entry and runner" {
  bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1

  local entry_id
  entry_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  run bash "$CRON_SH" cancel "$entry_id"
  assert_eq "cancel exits 0" "0" "$status"
  assert_match "cancel output confirms" "Cancelled:" "$output"
  assert_eq "registry is empty after cancel" "0" "$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")"
  assert_not_exists "runner removed after cancel" "${CEKERNEL_VAR_DIR}/runners/${entry_id}.sh"
}

@test "cron.sh cancel nonexistent ID fails" {
  run bash "$CRON_SH" cancel "nonexistent-id"
  [[ "$status" -ne 0 ]]
}

@test "cron.sh cancel removes launchd stdout/stderr logs but preserves run.log" {
  bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1

  local entry_id
  entry_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  # Simulate launchd log files
  touch "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stdout.log"
  touch "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stderr.log"
  touch "${CEKERNEL_VAR_DIR}/logs/${entry_id}.run.log"

  run bash "$CRON_SH" cancel "$entry_id"
  assert_eq "cancel exits 0" "0" "$status"
  assert_not_exists "stdout.log removed after cancel" "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stdout.log"
  assert_not_exists "stderr.log removed after cancel" "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stderr.log"
  assert_file_exists "run.log preserved after cancel" "${CEKERNEL_VAR_DIR}/logs/${entry_id}.run.log"
}

# ═══════════════════════════════════════
# usage
# ═══════════════════════════════════════

@test "cron.sh with no subcommand shows usage and exits 1" {
  run bash "$CRON_SH"
  [[ "$status" -ne 0 ]]
}
