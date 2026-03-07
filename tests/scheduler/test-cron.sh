#!/usr/bin/env bash
# test-cron.sh — Tests for scheduler/cron.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CRON_SH="${CEKERNEL_DIR}/scripts/scheduler/cron.sh"

echo "test: scheduler/cron.sh"

# ── Setup: isolated environment ──
setup() {
  export CEKERNEL_VAR_DIR="$(mktemp -d)"
  mkdir -p "${CEKERNEL_VAR_DIR}/runners" "${CEKERNEL_VAR_DIR}/logs"
  echo '[]' > "${CEKERNEL_VAR_DIR}/schedules.json"

  # Mock repo with .claude/settings.json
  export MOCK_REPO="$(mktemp -d)"
  mkdir -p "${MOCK_REPO}/.claude"
  echo '{"permissions":{"allow":["Bash"]}}' > "${MOCK_REPO}/.claude/settings.json"

  # Mock launchd dir for macOS backend
  export CEKERNEL_LAUNCHD_DIR="$(mktemp -d)"

  # Mock crontab file for Linux backend
  export _CRON_CRONTAB_FILE="$(mktemp)"
  echo "" > "$_CRON_CRONTAB_FILE"

  # Mock binaries only when not available (CI compatibility)
  export _MOCK_BIN="$(mktemp -d)"
  for cmd in launchctl claude gh git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo '#!/bin/bash' > "${_MOCK_BIN}/${cmd}" && chmod +x "${_MOCK_BIN}/${cmd}"
    fi
  done
  export PATH="${_MOCK_BIN}:${PATH}"

  # Satisfy preflight API key check
  export ANTHROPIC_API_KEY="test-key"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR" "$MOCK_REPO" "$CEKERNEL_LAUNCHD_DIR" "$_MOCK_BIN"
  rm -f "$_CRON_CRONTAB_FILE"
}

# ── Test 1: register creates runner and registry entry ──
setup
OUTPUT=$(bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" 2>&1)
ENTRY_COUNT=$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_eq "register adds registry entry" "1" "$ENTRY_COUNT"

# Check runner file exists
RUNNER_ID=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_file_exists "runner script created" "${CEKERNEL_VAR_DIR}/runners/${RUNNER_ID}.sh"
teardown

# ── Test 2: register output contains ID and details ──
setup
OUTPUT=$(bash "$CRON_SH" register --label deploy --schedule "30 */6 * * *" --repo "$MOCK_REPO" 2>&1)
assert_match "output contains Registered" "Registered:" "$OUTPUT"
assert_match "output contains Schedule" "30 \*/6 \* \* \*" "$OUTPUT"
assert_match "output contains Label" "deploy" "$OUTPUT"
teardown

# ── Test 3: register without --label or --prompt fails ──
setup
if bash "$CRON_SH" register --schedule "0 9 * * *" --repo "$MOCK_REPO" 2>/dev/null; then
  assert_eq "register without --label or --prompt fails" "1" "0"
else
  assert_eq "register without --label or --prompt fails" "1" "1"
fi
teardown

# ── Test 4: register without --schedule fails ──
setup
if bash "$CRON_SH" register --label ready --repo "$MOCK_REPO" 2>/dev/null; then
  assert_eq "register without --schedule fails" "1" "0"
else
  assert_eq "register without --schedule fails" "1" "1"
fi
teardown

# ── Test 5: list with no entries ──
setup
OUTPUT=$(bash "$CRON_SH" list 2>&1)
assert_match "list shows no schedules message" "No cron schedules registered" "$OUTPUT"
teardown

# ── Test 6: list after register shows entry ──
setup
bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1
OUTPUT=$(bash "$CRON_SH" list 2>&1)
ENTRY_ID=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_match "list shows registered ID" "$ENTRY_ID" "$OUTPUT"
assert_match "list shows schedule" "0 9" "$OUTPUT"
assert_match "list shows label" "ready" "$OUTPUT"
teardown

# ── Test 7: cancel removes entry ──
setup
bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY_ID=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
OUTPUT=$(bash "$CRON_SH" cancel "$ENTRY_ID" 2>&1)
assert_match "cancel output confirms" "Cancelled:" "$OUTPUT"
ENTRY_COUNT=$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_eq "registry is empty after cancel" "0" "$ENTRY_COUNT"
assert_not_exists "runner removed after cancel" "${CEKERNEL_VAR_DIR}/runners/${ENTRY_ID}.sh"
teardown

# ── Test 8: cancel nonexistent ID fails ──
setup
if bash "$CRON_SH" cancel "nonexistent-id" 2>/dev/null; then
  assert_eq "cancel nonexistent fails" "1" "0"
else
  assert_eq "cancel nonexistent fails" "1" "1"
fi
teardown

# ── Test 9: registry entry has correct schema ──
setup
bash "$CRON_SH" register --label ready --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
TYPE=$(echo "$ENTRY" | jq -r '.type')
LABEL=$(echo "$ENTRY" | jq -r '.label')
SCHEDULE=$(echo "$ENTRY" | jq -r '.schedule')
assert_eq "entry type is cron" "cron" "$TYPE"
assert_eq "entry label is ready" "ready" "$LABEL"
assert_eq "entry schedule is correct" "0 9 * * 1-5" "$SCHEDULE"
assert_match "entry id starts with cekernel-cron-" "^cekernel-cron-" "$(echo "$ENTRY" | jq -r '.id')"
assert_match "entry created_at is ISO timestamp" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$(echo "$ENTRY" | jq -r '.created_at')"
teardown

# ── Test 10: register with --prompt succeeds ──
setup
OUTPUT=$(bash "$CRON_SH" register --prompt "run my custom task" --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" 2>&1)
ENTRY_COUNT=$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_eq "register with --prompt adds entry" "1" "$ENTRY_COUNT"
assert_match "output contains Prompt" "run my custom task" "$OUTPUT"
teardown

# ── Test 11: --prompt takes precedence over --label ──
setup
bash "$CRON_SH" register --label ready --prompt "custom prompt" --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
PROMPT_VAL=$(echo "$ENTRY" | jq -r '.prompt')
assert_eq "prompt field has --prompt value" "custom prompt" "$PROMPT_VAL"
teardown

# ── Test 12: --label generates dispatch prompt in registry ──
setup
bash "$CRON_SH" register --label deploy --schedule "0 9 * * 1-5" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
PROMPT_VAL=$(echo "$ENTRY" | jq -r '.prompt')
assert_eq "label generates dispatch prompt" "/dispatch --env headless --label deploy" "$PROMPT_VAL"
teardown

# ── Test 13: no subcommand shows usage ──
setup
if bash "$CRON_SH" 2>/dev/null; then
  assert_eq "no subcommand shows usage and exits 1" "1" "0"
else
  assert_eq "no subcommand shows usage and exits 1" "1" "1"
fi
teardown

report_results
