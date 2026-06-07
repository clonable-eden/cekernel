#!/usr/bin/env bash
# test-bare-mode.sh — Tests for bare-mode.sh
#
# Verifies that cekernel_bare_prepare populates CEKERNEL_BARE_FLAGS with
# the correct flag set based on CEKERNEL_USE_BARE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BARE_SCRIPT="${CEKERNEL_DIR}/scripts/shared/bare-mode.sh"

echo "test: bare-mode.sh"

# ── Test 1: file exists ──
assert_file_exists "bare-mode.sh exists" "$BARE_SCRIPT"

# ── Test 2: disabled by default (env unset) → no flags ──
RESULT=$(
  unset CEKERNEL_USE_BARE
  CEKERNEL_BARE_FLAGS=("initial")
  source "$BARE_SCRIPT"
  cekernel_bare_prepare
  echo "${#CEKERNEL_BARE_FLAGS[@]}"
)
assert_eq "CEKERNEL_USE_BARE unset → empty flags" "0" "$RESULT"

# ── Test 3: CEKERNEL_USE_BARE=0 → no flags ──
RESULT=$(
  export CEKERNEL_USE_BARE=0
  CEKERNEL_BARE_FLAGS=("initial")
  source "$BARE_SCRIPT"
  cekernel_bare_prepare
  echo "${#CEKERNEL_BARE_FLAGS[@]}"
)
assert_eq "CEKERNEL_USE_BARE=0 → empty flags" "0" "$RESULT"

# ── Test 4: CEKERNEL_USE_BARE=1 (no worktree arg) → --bare --plugin-dir <root> ──
RESULT=$(
  export CEKERNEL_USE_BARE=1
  source "$BARE_SCRIPT"
  cekernel_bare_prepare
  printf '%s\n' "${CEKERNEL_BARE_FLAGS[@]}"
)
EXPECTED="--bare
--plugin-dir
${CEKERNEL_DIR}"
assert_eq "CEKERNEL_USE_BARE=1 → bare + plugin-dir" "$EXPECTED" "$RESULT"

# ── Test 5: CEKERNEL_USE_BARE=1 with worktree arg → adds --add-dir ──
TMP_WORKTREE="$(mktemp -d)"
RESULT=$(
  export CEKERNEL_USE_BARE=1
  source "$BARE_SCRIPT"
  cekernel_bare_prepare "$TMP_WORKTREE"
  printf '%s\n' "${CEKERNEL_BARE_FLAGS[@]}"
)
EXPECTED="--bare
--plugin-dir
${CEKERNEL_DIR}
--add-dir
${TMP_WORKTREE}"
assert_eq "worktree arg → adds --add-dir" "$EXPECTED" "$RESULT"
rm -rf "$TMP_WORKTREE"

# ── Test 6: cekernel_use_bare exit code ──
EXIT=$(
  unset CEKERNEL_USE_BARE
  source "$BARE_SCRIPT"
  cekernel_use_bare && echo enabled || echo disabled
)
assert_eq "cekernel_use_bare returns disabled when unset" "disabled" "$EXIT"

EXIT=$(
  export CEKERNEL_USE_BARE=1
  source "$BARE_SCRIPT"
  cekernel_use_bare && echo enabled || echo disabled
)
assert_eq "cekernel_use_bare returns enabled when set to 1" "enabled" "$EXIT"

report_results
