#!/usr/bin/env bash
# test-load-env-zsh-compat.sh — Verify load-env.sh works when sourced in zsh
#
# When sourced in zsh, BASH_SOURCE[0] does not resolve correctly,
# causing path resolution to fail. See #403, #405.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: load-env zsh compat"

# Skip if zsh is not available
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP: zsh not available"
  report_results
  exit 0
fi

# ── Setup ──
TEST_ENV_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEST_ENV_DIR"
}
trap cleanup EXIT

# Create a test env file
mkdir -p "${TEST_ENV_DIR}/plugin-envs"
cat > "${TEST_ENV_DIR}/plugin-envs/default.env" <<'ENVFILE'
CEKERNEL_TEST_ZSH_VAR=zsh_compat_ok
ENVFILE

# ── Test 1: zsh source resolves _LOAD_ENV_DIR correctly ──
ZSH_OUTPUT=$(zsh -c "
  source '${CEKERNEL_DIR}/scripts/shared/load-env.sh' 2>&1
  echo \"\${_LOAD_ENV_DIR}\"
" 2>&1)
# Should resolve to the actual shared/ directory, not empty
assert_match "zsh: _LOAD_ENV_DIR resolves to scripts/shared" "scripts/shared" "$ZSH_OUTPUT"

# ── Test 2: zsh source loads env file without error ──
ZSH_EXIT=0
ZSH_OUTPUT=$(zsh -c "
  export _CEKERNEL_PLUGIN_ENVS_DIR='${TEST_ENV_DIR}/plugin-envs'
  export _CEKERNEL_PROJECT_ENVS_DIR='${TEST_ENV_DIR}/nonexistent'
  export _CEKERNEL_USER_ENVS_DIR='${TEST_ENV_DIR}/nonexistent'
  source '${CEKERNEL_DIR}/scripts/shared/load-env.sh' 2>&1
  echo \"SOURCE_OK:\${CEKERNEL_TEST_ZSH_VAR:-unset}\"
" 2>&1) || ZSH_EXIT=$?
assert_match "zsh: load-env.sh sources and loads env var" "SOURCE_OK:zsh_compat_ok" "$ZSH_OUTPUT"

# ── Test 3: bash source still works (regression) ──
BASH_EXIT=0
BASH_OUTPUT=$(bash -c "
  export _CEKERNEL_PLUGIN_ENVS_DIR='${TEST_ENV_DIR}/plugin-envs'
  export _CEKERNEL_PROJECT_ENVS_DIR='${TEST_ENV_DIR}/nonexistent'
  export _CEKERNEL_USER_ENVS_DIR='${TEST_ENV_DIR}/nonexistent'
  source '${CEKERNEL_DIR}/scripts/shared/load-env.sh' 2>&1
  echo \"SOURCE_OK:\${CEKERNEL_TEST_ZSH_VAR:-unset}\"
" 2>&1) || BASH_EXIT=$?
assert_match "bash: load-env.sh still works (regression check)" "SOURCE_OK:zsh_compat_ok" "$BASH_OUTPUT"

report_results
