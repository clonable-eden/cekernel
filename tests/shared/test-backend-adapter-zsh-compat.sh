#!/usr/bin/env bash
# test-backend-adapter-zsh-compat.sh — Verify backend-adapter.sh and backends work in zsh
#
# When sourced in zsh, BASH_SOURCE[0] does not resolve correctly,
# causing backend file path resolution to fail. See #403, #405.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: backend-adapter zsh compat"

# Skip if zsh is not available
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP: zsh not available"
  report_results
  exit 0
fi

# ── Test 1: backend-adapter.sh — zsh source resolves _BACKEND_ADAPTER_DIR ──
ZSH_OUTPUT=$(zsh -c "
  export CEKERNEL_BACKEND=headless
  source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' 2>&1
  echo \"DIR:\${_BACKEND_ADAPTER_DIR}\"
" 2>&1)
assert_match "zsh: _BACKEND_ADAPTER_DIR resolves to scripts/shared" "scripts/shared" "$ZSH_OUTPUT"

# ── Test 2: backend-adapter.sh — zsh source loads headless backend without error ──
ZSH_EXIT=0
ZSH_OUTPUT=$(zsh -c "
  export CEKERNEL_BACKEND=headless
  source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' 2>&1
  if typeset -f backend_available >/dev/null 2>&1; then
    echo 'FUNC_OK'
  else
    echo 'FUNC_MISSING'
  fi
" 2>&1) || ZSH_EXIT=$?
assert_match "zsh: headless backend functions loaded" "FUNC_OK" "$ZSH_OUTPUT"

# ── Test 3: tmux backend — zsh source resolves _TMUX_BACKEND_DIR ──
ZSH_OUTPUT=$(zsh -c "
  export CEKERNEL_BACKEND=tmux
  source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' 2>&1
  echo \"DIR:\${_TMUX_BACKEND_DIR}\"
" 2>&1)
assert_match "zsh: _TMUX_BACKEND_DIR resolves to backends dir" "backends" "$ZSH_OUTPUT"

# ── Test 4: wezterm backend — zsh source resolves _WEZTERM_BACKEND_DIR ──
ZSH_OUTPUT=$(zsh -c "
  export CEKERNEL_BACKEND=wezterm
  source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' 2>&1
  echo \"DIR:\${_WEZTERM_BACKEND_DIR}\"
" 2>&1)
assert_match "zsh: _WEZTERM_BACKEND_DIR resolves to backends dir" "backends" "$ZSH_OUTPUT"

# ── Test 5: bash source still works (regression) ──
BASH_EXIT=0
BASH_OUTPUT=$(bash -c "
  export CEKERNEL_BACKEND=headless
  source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' 2>&1
  if declare -f backend_available >/dev/null 2>&1; then
    echo 'FUNC_OK'
  else
    echo 'FUNC_MISSING'
  fi
" 2>&1) || BASH_EXIT=$?
assert_match "bash: backend-adapter.sh still works (regression check)" "FUNC_OK" "$BASH_OUTPUT"

report_results
