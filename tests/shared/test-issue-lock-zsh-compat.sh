#!/usr/bin/env bash
# test-issue-lock-zsh-compat.sh — Verify issue-lock.sh works when sourced in zsh
#
# When sourced in zsh, BASH_SOURCE[0] does not resolve correctly,
# causing load-env.sh to not be found. See #403.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: issue-lock zsh compat"

# Skip if zsh is not available
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP: zsh not available"
  report_results
  exit 0
fi

# ── Setup ──
TEST_VAR_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEST_VAR_DIR"
}
trap cleanup EXIT

# ── Test 1: zsh source resolves load-env.sh correctly (no error) ──
ZSH_OUTPUT=$(zsh -c "
  export CEKERNEL_VAR_DIR='${TEST_VAR_DIR}'
  source '${CEKERNEL_DIR}/scripts/shared/issue-lock.sh' 2>&1
  echo 'SOURCE_OK'
" 2>&1)
assert_match "zsh: issue-lock.sh sources without error" "SOURCE_OK" "$ZSH_OUTPUT"

# Verify no "no such file or directory" error for load-env.sh
if echo "$ZSH_OUTPUT" | grep -q "no such file or directory"; then
  echo "  FAIL: zsh: load-env.sh resolution failed"
  echo "    output: ${ZSH_OUTPUT}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: zsh: no load-env.sh resolution error"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 2: zsh source — lock functions are available ──
ZSH_EXIT=0
zsh -c "
  export CEKERNEL_VAR_DIR='${TEST_VAR_DIR}'
  source '${CEKERNEL_DIR}/scripts/shared/issue-lock.sh' 2>/dev/null
  # Verify function is available and works
  HASH=\$(issue_lock_repo_hash '/tmp/test-repo')
  [[ -n \"\$HASH\" ]]
" 2>&1 || ZSH_EXIT=$?
assert_eq "zsh: issue_lock_repo_hash function works" "0" "$ZSH_EXIT"

# ── Test 3: zsh source — lock acquire/release cycle works ──
ZSH_EXIT=0
zsh -c "
  export CEKERNEL_VAR_DIR='${TEST_VAR_DIR}'
  source '${CEKERNEL_DIR}/scripts/shared/issue-lock.sh' 2>/dev/null
  issue_lock_acquire '/tmp/test-zsh-repo' 403
  issue_lock_check '/tmp/test-zsh-repo' 403
  issue_lock_release '/tmp/test-zsh-repo' 403
" 2>&1 || ZSH_EXIT=$?
assert_eq "zsh: lock acquire/check/release cycle works" "0" "$ZSH_EXIT"

# ── Test 4: bash source still works (regression) ──
BASH_EXIT=0
bash -c "
  export CEKERNEL_VAR_DIR='${TEST_VAR_DIR}'
  source '${CEKERNEL_DIR}/scripts/shared/issue-lock.sh'
  issue_lock_repo_hash '/tmp/test-repo' >/dev/null
" 2>&1 || BASH_EXIT=$?
assert_eq "bash: issue-lock.sh still works (regression check)" "0" "$BASH_EXIT"

report_results
