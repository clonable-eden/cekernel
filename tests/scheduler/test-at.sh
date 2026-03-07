#!/usr/bin/env bash
# test-at.sh — Tests for scheduler/at.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AT_SH="${CEKERNEL_DIR}/scripts/scheduler/at.sh"

echo "test: scheduler/at.sh"

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

  # Mock binaries only when not available (CI compatibility)
  export _MOCK_BIN="$(mktemp -d)"
  for cmd in launchctl claude gh git at atq atrm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo '#!/bin/bash' > "${_MOCK_BIN}/${cmd}" && chmod +x "${_MOCK_BIN}/${cmd}"
    fi
  done

  # On macOS, mock launchctl to avoid real launchd side effects
  if [[ "$(uname)" == "Darwin" ]]; then
    echo '#!/bin/bash' > "${_MOCK_BIN}/launchctl" && chmod +x "${_MOCK_BIN}/launchctl"
  fi

  # Mock at to return a job number (for atd backend on Linux)
  cat > "${_MOCK_BIN}/at" <<'MOCK_AT'
#!/bin/bash
cat > /dev/null
echo "job 42 at Mon Mar 15 09:00:00 2026" >&2
MOCK_AT
  chmod +x "${_MOCK_BIN}/at"

  # Mock systemctl for atd preflight check (Linux CI)
  cat > "${_MOCK_BIN}/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/bash
# Simulate atd is active
exit 0
MOCK_SYSTEMCTL
  chmod +x "${_MOCK_BIN}/systemctl"

  export PATH="${_MOCK_BIN}:${PATH}"

  # Satisfy preflight API key check
  export ANTHROPIC_API_KEY="test-key"
}

teardown() {
  rm -rf "$CEKERNEL_VAR_DIR" "$MOCK_REPO" "$CEKERNEL_LAUNCHD_DIR" "$_MOCK_BIN"
}

# ── Test 1: register creates runner and registry entry ──
setup
OUTPUT=$(bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" 2>&1)
ENTRY_COUNT=$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_eq "register adds registry entry" "1" "$ENTRY_COUNT"

RUNNER_ID=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_file_exists "runner script created" "${CEKERNEL_VAR_DIR}/runners/${RUNNER_ID}.sh"
teardown

# ── Test 2: register output contains ID and details ──
setup
OUTPUT=$(bash "$AT_SH" register --label deploy --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" 2>&1)
assert_match "output contains Registered" "Registered:" "$OUTPUT"
assert_match "output contains Schedule" "2026-03-15T09:00" "$OUTPUT"
assert_match "output contains Label" "deploy" "$OUTPUT"
teardown

# ── Test 3: register without --label or --prompt fails ──
setup
if bash "$AT_SH" register --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" 2>/dev/null; then
  assert_eq "register without --label or --prompt fails" "1" "0"
else
  assert_eq "register without --label or --prompt fails" "1" "1"
fi
teardown

# ── Test 4: register without --schedule fails ──
setup
if bash "$AT_SH" register --label ready --repo "$MOCK_REPO" 2>/dev/null; then
  assert_eq "register without --schedule fails" "1" "0"
else
  assert_eq "register without --schedule fails" "1" "1"
fi
teardown

# ── Test 5: list with no entries ──
setup
OUTPUT=$(bash "$AT_SH" list 2>&1)
assert_match "list shows no schedules message" "No at schedules registered" "$OUTPUT"
teardown

# ── Test 6: list after register shows entry ──
setup
bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1
OUTPUT=$(bash "$AT_SH" list 2>&1)
ENTRY_ID=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_match "list shows registered ID" "$ENTRY_ID" "$OUTPUT"
assert_match "list shows schedule" "2026-03-15" "$OUTPUT"
assert_match "list shows label" "ready" "$OUTPUT"
teardown

# ── Test 7: cancel removes entry ──
setup
bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY_ID=$(jq -r '.[0].id' "${CEKERNEL_VAR_DIR}/schedules.json")
OUTPUT=$(bash "$AT_SH" cancel "$ENTRY_ID" 2>&1)
assert_match "cancel output confirms" "Cancelled:" "$OUTPUT"
ENTRY_COUNT=$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_eq "registry is empty after cancel" "0" "$ENTRY_COUNT"
assert_not_exists "runner removed after cancel" "${CEKERNEL_VAR_DIR}/runners/${ENTRY_ID}.sh"
teardown

# ── Test 8: cancel nonexistent ID fails ──
setup
if bash "$AT_SH" cancel "nonexistent-id" 2>/dev/null; then
  assert_eq "cancel nonexistent fails" "1" "0"
else
  assert_eq "cancel nonexistent fails" "1" "1"
fi
teardown

# ── Test 9: registry entry has correct schema ──
setup
bash "$AT_SH" register --label ready --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
TYPE=$(echo "$ENTRY" | jq -r '.type')
LABEL=$(echo "$ENTRY" | jq -r '.label')
SCHEDULE=$(echo "$ENTRY" | jq -r '.schedule')
assert_eq "entry type is at" "at" "$TYPE"
assert_eq "entry label is ready" "ready" "$LABEL"
assert_eq "entry schedule is correct" "2026-03-15T09:00" "$SCHEDULE"
assert_match "entry id starts with cekernel-at-" "^cekernel-at-" "$(echo "$ENTRY" | jq -r '.id')"
assert_match "entry created_at is ISO timestamp" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$(echo "$ENTRY" | jq -r '.created_at')"
teardown

# ── Test 10: register with --prompt succeeds ──
setup
OUTPUT=$(bash "$AT_SH" register --prompt "run my custom task" --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" 2>&1)
ENTRY_COUNT=$(jq 'length' "${CEKERNEL_VAR_DIR}/schedules.json")
assert_eq "register with --prompt adds entry" "1" "$ENTRY_COUNT"
assert_match "output contains Prompt" "run my custom task" "$OUTPUT"
teardown

# ── Test 11: --prompt takes precedence over --label ──
setup
bash "$AT_SH" register --label ready --prompt "custom prompt" --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
PROMPT_VAL=$(echo "$ENTRY" | jq -r '.prompt')
assert_eq "prompt field has --prompt value" "custom prompt" "$PROMPT_VAL"
teardown

# ── Test 12: --label generates dispatch prompt in registry ──
setup
bash "$AT_SH" register --label deploy --schedule "2026-03-15T09:00" --repo "$MOCK_REPO" >/dev/null 2>&1
ENTRY=$(jq '.[0]' "${CEKERNEL_VAR_DIR}/schedules.json")
PROMPT_VAL=$(echo "$ENTRY" | jq -r '.prompt')
assert_eq "label generates dispatch prompt" "/dispatch --env headless --label deploy" "$PROMPT_VAL"
teardown

# ── Test 13: no subcommand shows usage ──
setup
if bash "$AT_SH" 2>/dev/null; then
  assert_eq "no subcommand shows usage and exits 1" "1" "0"
else
  assert_eq "no subcommand shows usage and exits 1" "1" "1"
fi
teardown

report_results
