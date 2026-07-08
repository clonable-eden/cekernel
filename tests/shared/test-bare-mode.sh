#!/usr/bin/env bash
# test-bare-mode.sh — Tests for bare-mode.sh (ADR-0016 Phase 0 + Amendment 1)
#
# Verifies the explicit-context flag builder for claude spawns:
#   bare_mode_prepare   — populates CEKERNEL_BARE_FLAGS array (--bare only
#                         when a bare-compatible auth path exists; the
#                         OAuth branch is covered in bare-mode.bats)
#   bare_mode_flags     — emits shell-quoted flag string for generated runners
#   bare_mode_preflight — fails noisily when no --bare-compatible auth exists
#                         (hard gate for the scheduled cron/at path only)
# The prepare/flags tests pin ANTHROPIC_API_KEY so the --bare branch is
# asserted deterministically regardless of the ambient environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BARE_SCRIPT="${CEKERNEL_DIR}/scripts/shared/bare-mode.sh"

echo "test: bare-mode"

# ── Test 1: bare-mode.sh exists ──
assert_file_exists "bare-mode.sh exists" "$BARE_SCRIPT"

# ── Test 2: bare_mode_prepare without context dir → --bare --plugin-dir <root> ──
RESULT=$(
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS
  source "$BARE_SCRIPT"
  bare_mode_prepare
  printf '%s\n' "${CEKERNEL_BARE_FLAGS[@]}"
)
EXPECTED="--bare
--plugin-dir
${CEKERNEL_DIR}"
assert_eq "prepare without context dir" "$EXPECTED" "$RESULT"

# ── Test 3: bare_mode_prepare with context dir → adds --add-dir ──
TMP_DIR="$(mktemp -d)"
RESULT=$(
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS
  source "$BARE_SCRIPT"
  bare_mode_prepare "$TMP_DIR"
  printf '%s\n' "${CEKERNEL_BARE_FLAGS[@]}"
)
EXPECTED="--bare
--plugin-dir
${CEKERNEL_DIR}
--add-dir
${TMP_DIR}"
assert_eq "prepare with context dir adds --add-dir" "$EXPECTED" "$RESULT"

# ── Test 4: CEKERNEL_CLAUDE_SETTINGS set → adds --settings <path> ──
RESULT=$(
  export CEKERNEL_CLAUDE_SETTINGS="/tmp/my-settings.json"
  source "$BARE_SCRIPT"
  bare_mode_prepare "$TMP_DIR"
  printf '%s\n' "${CEKERNEL_BARE_FLAGS[@]}"
)
EXPECTED="--bare
--plugin-dir
${CEKERNEL_DIR}
--add-dir
${TMP_DIR}
--settings
/tmp/my-settings.json"
assert_eq "CEKERNEL_CLAUDE_SETTINGS adds --settings" "$EXPECTED" "$RESULT"

# ── Test 5: bare_mode_flags emits a single-line flag string ──
RESULT=$(
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS
  source "$BARE_SCRIPT"
  bare_mode_flags "$TMP_DIR"
)
assert_match "flags string contains --bare" "--bare" "$RESULT"
assert_match "flags string contains plugin-dir" "--plugin-dir ${CEKERNEL_DIR}" "$RESULT"
assert_match "flags string contains add-dir" "--add-dir ${TMP_DIR}" "$RESULT"

# ── Test 6: bare_mode_flags quotes paths with spaces ──
SPACE_DIR="${TMP_DIR}/with space"
mkdir -p "$SPACE_DIR"
RESULT=$(
  export ANTHROPIC_API_KEY="test-key-bare"
  unset CEKERNEL_CLAUDE_SETTINGS
  source "$BARE_SCRIPT"
  bare_mode_flags "$SPACE_DIR"
)
# eval the string back into an array — the space path must survive as one word
eval "FLAGS=($RESULT)"
LAST_INDEX=$(( ${#FLAGS[@]} - 1 ))
assert_eq "quoted path survives eval round-trip" "$SPACE_DIR" "${FLAGS[$LAST_INDEX]}"

# ── Test 7: preflight fails when no auth path is available ──
EXIT_CODE=0
OUTPUT=$(
  unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS
  source "$BARE_SCRIPT"
  bare_mode_preflight 2>&1
) || EXIT_CODE=$?
assert_eq "preflight fails without auth" "1" "$EXIT_CODE"

# ── Test 8: preflight failure message is actionable (mentions both options) ──
assert_match "preflight error mentions ANTHROPIC_API_KEY" "ANTHROPIC_API_KEY" "$OUTPUT"
assert_match "preflight error mentions CEKERNEL_CLAUDE_SETTINGS" "CEKERNEL_CLAUDE_SETTINGS" "$OUTPUT"

# ── Test 9: preflight passes with ANTHROPIC_API_KEY ──
EXIT_CODE=0
(
  export ANTHROPIC_API_KEY="test-key"
  unset CEKERNEL_CLAUDE_SETTINGS
  source "$BARE_SCRIPT"
  bare_mode_preflight
) || EXIT_CODE=$?
assert_eq "preflight passes with ANTHROPIC_API_KEY" "0" "$EXIT_CODE"

# ── Test 10: preflight passes with CEKERNEL_CLAUDE_SETTINGS ──
SETTINGS_FILE="${TMP_DIR}/settings.json"
echo '{}' > "$SETTINGS_FILE"
EXIT_CODE=0
(
  unset ANTHROPIC_API_KEY
  export CEKERNEL_CLAUDE_SETTINGS="$SETTINGS_FILE"
  source "$BARE_SCRIPT"
  bare_mode_preflight
) || EXIT_CODE=$?
assert_eq "preflight passes with CEKERNEL_CLAUDE_SETTINGS" "0" "$EXIT_CODE"

# ── Test 11: preflight fails when CEKERNEL_CLAUDE_SETTINGS points to missing file ──
EXIT_CODE=0
(
  unset ANTHROPIC_API_KEY
  export CEKERNEL_CLAUDE_SETTINGS="${TMP_DIR}/no-such-settings.json"
  source "$BARE_SCRIPT"
  bare_mode_preflight 2>/dev/null
) || EXIT_CODE=$?
assert_eq "preflight fails for missing settings file" "1" "$EXIT_CODE"

# ── Cleanup ──
rm -rf "$TMP_DIR"

report_results
