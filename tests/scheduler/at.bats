#!/usr/bin/env bats
# at.bats — bats-core tests for scripts/scheduler/at.sh (ADR-0017 Decision 4)
#
# CLI contract of the /at skill backend: register / list / cancel.
# Consolidates legacy tests/scheduler/test-at.sh.
#
# OS scheduler side effects (launchctl, at/atq/atrm) and preflight
# presence checks (claude/gh/git) are isolated via PATH shims (mock_bin).

load '../helpers/assertions'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AT_SH="${CEKERNEL_DIR}/scripts/scheduler/at.sh"

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

  # Preflight presence checks — never invoked for real in these tests
  mock_bin claude ':'
  mock_bin gh ':'
  mock_bin git ':'
  # macOS backend: no real launchd side effects
  mock_bin launchctl ':'
  # Linux backend: at reports a job number like the real at (on stderr)
  mock_bin at 'cat > /dev/null
echo "job 42 at Mon Mar 15 09:00:00 2026" >&2'
  mock_bin atq ':'
  mock_bin atrm ':'
  # Linux preflight: simulate atd active
  mock_bin systemctl 'exit 0'
}

# ═══════════════════════════════════════
# register
# ═══════════════════════════════════════

@test "at.sh register adds registry entry and creates runner" {
  run bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "register adds registry entry" "1" "$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")"

  local runner_id
  runner_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  assert_file_exists "runner script created" "${CEKERNEL_VAR_DIR}/runners/${runner_id}.sh"
}

@test "at.sh register output contains ID and details" {
  run bash "$AT_SH" register --label deploy --schedule "2026-03-15T09:00" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_match "output contains Registered" "Registered:" "$output"
  assert_match "output contains Schedule" "2026-03-15T09:00" "$output"
  assert_match "output contains Label" "deploy" "$output"
}

@test "at.sh register without --label or --prompt fails" {
  run bash "$AT_SH" register --schedule "2026-03-15T09:00" --repo "$MOCK_REPO"
  [[ "$status" -ne 0 ]]
}

@test "at.sh register without --schedule fails" {
  run bash "$AT_SH" register --label ready --repo "$MOCK_REPO"
  [[ "$status" -ne 0 ]]
}

@test "at.sh register with --prompt succeeds" {
  run bash "$AT_SH" register --prompt "run my custom task" --schedule "2026-03-15T09:00" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "register with --prompt adds entry" "1" "$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")"
  assert_match "output contains Prompt" "run my custom task" "$output"
}

@test "at.sh --prompt takes precedence over --label" {
  run bash "$AT_SH" register --label ready --prompt "custom prompt" --schedule "2026-03-15T09:00" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "prompt field has --prompt value" "custom prompt" \
    "$(jq -r '.[0].prompt' "${CEKERNEL_VAR_DIR}/schedules.json")"
}

@test "at.sh --label generates dispatch prompt in registry" {
  run bash "$AT_SH" register --label deploy --schedule "2026-03-15T09:00" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"
  assert_eq "label generates dispatch prompt" "/dispatch --env headless --label deploy" \
    "$(jq -r '.[0].prompt' "${CEKERNEL_VAR_DIR}/schedules.json")"
}

@test "at.sh registry entry has correct schema" {
  run bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO"
  assert_eq "register exits 0" "0" "$status"

  local entry
  entry=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
  assert_eq "entry type is at" "at" "$(echo "$entry" | jq -r '.type')"
  assert_eq "entry label is ready" "ready" "$(echo "$entry" | jq -r '.label')"
  assert_eq "entry schedule is correct" "2026-03-15T09:00" "$(echo "$entry" | jq -r '.schedule')"
  assert_match "entry id starts with cekernel-at-" "^cekernel-at-" "$(echo "$entry" | jq -r '.id')"
  assert_match "entry created_at is ISO timestamp" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$(echo "$entry" | jq -r '.created_at')"
}

# ═══════════════════════════════════════
# list
# ═══════════════════════════════════════

@test "at.sh list with no entries shows message" {
  run bash "$AT_SH" list
  assert_eq "list exits 0" "0" "$status"
  assert_match "list shows no schedules message" "No at schedules registered" "$output"
}

@test "at.sh list after register shows entry" {
  bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1

  local entry_id
  entry_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  run bash "$AT_SH" list
  assert_eq "list exits 0" "0" "$status"
  assert_match "list shows registered ID" "$entry_id" "$output"
  assert_match "list shows schedule" "2026-03-15" "$output"
  assert_match "list shows label" "ready" "$output"
}

# ═══════════════════════════════════════
# cancel
# ═══════════════════════════════════════

@test "at.sh cancel removes entry and runner" {
  bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1

  local entry_id
  entry_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  run bash "$AT_SH" cancel "$entry_id"
  assert_eq "cancel exits 0" "0" "$status"
  assert_match "cancel output confirms" "Cancelled:" "$output"
  assert_eq "registry is empty after cancel" "0" "$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")"
  assert_not_exists "runner removed after cancel" "${CEKERNEL_VAR_DIR}/runners/${entry_id}.sh"
}

@test "at.sh cancel nonexistent ID fails" {
  run bash "$AT_SH" cancel "nonexistent-id"
  [[ "$status" -ne 0 ]]
}

@test "at.sh cancel removes launchd stdout/stderr logs but preserves run.log" {
  bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1

  local entry_id
  entry_id=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
  # Simulate launchd log files
  touch "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stdout.log"
  touch "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stderr.log"
  touch "${CEKERNEL_VAR_DIR}/logs/${entry_id}.run.log"

  run bash "$AT_SH" cancel "$entry_id"
  assert_eq "cancel exits 0" "0" "$status"
  assert_not_exists "stdout.log removed after cancel" "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stdout.log"
  assert_not_exists "stderr.log removed after cancel" "${CEKERNEL_VAR_DIR}/logs/${entry_id}.stderr.log"
  assert_file_exists "run.log preserved after cancel" "${CEKERNEL_VAR_DIR}/logs/${entry_id}.run.log"
}

# ═══════════════════════════════════════
# usage
# ═══════════════════════════════════════

@test "at.sh with no subcommand shows usage and exits 1" {
  run bash "$AT_SH"
  [[ "$status" -ne 0 ]]
}
