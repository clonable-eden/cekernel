#!/usr/bin/env bash
# test-terminal-backend-dispatch.sh — Tests for backend dispatch in terminal-adapter.sh
#
# Verifies that terminal-adapter.sh selects the correct backend based on
# CEKERNEL_TERMINAL env var.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: terminal-backend-dispatch"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-backend-dispatch-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Test 1: Default backend is wezterm ──
(
  unset CEKERNEL_TERMINAL 2>/dev/null || true
  source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"
  assert_eq "default CEKERNEL_TERMINAL_BACKEND is wezterm" "wezterm" "${CEKERNEL_TERMINAL_BACKEND:-}"
)

# ── Test 2: CEKERNEL_TERMINAL=wezterm selects wezterm backend ──
(
  export CEKERNEL_TERMINAL=wezterm
  source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"
  assert_eq "CEKERNEL_TERMINAL=wezterm selects wezterm" "wezterm" "${CEKERNEL_TERMINAL_BACKEND:-}"
)

# ── Test 3: CEKERNEL_TERMINAL=tmux selects tmux backend ──
(
  export CEKERNEL_TERMINAL=tmux
  source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"
  assert_eq "CEKERNEL_TERMINAL=tmux selects tmux" "tmux" "${CEKERNEL_TERMINAL_BACKEND:-}"
)

# ── Test 4: Unknown backend fails with error ──
(
  export CEKERNEL_TERMINAL=unknown_terminal
  if source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh" 2>/dev/null; then
    echo "  FAIL: unknown backend should cause an error"
    exit 1
  else
    echo "  PASS: unknown backend causes error"
  fi
)

# ── Test 5: wezterm backend provides terminal_available function ──
(
  export CEKERNEL_TERMINAL=wezterm
  source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"
  if declare -f terminal_available >/dev/null 2>&1; then
    echo "  PASS: wezterm backend defines terminal_available"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: wezterm backend should define terminal_available"
    ((TESTS_FAILED++)) || true
  fi
)

# ── Test 6: tmux backend provides terminal_available function ──
(
  export CEKERNEL_TERMINAL=tmux
  source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"
  if declare -f terminal_available >/dev/null 2>&1; then
    echo "  PASS: tmux backend defines terminal_available"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: tmux backend should define terminal_available"
    ((TESTS_FAILED++)) || true
  fi
)

# ── Test 7: tmux backend provides all required functions ──
REQUIRED_FUNCTIONS=(
  terminal_available
  terminal_resolve_workspace
  terminal_spawn_window
  terminal_run_command
  terminal_split_pane
  terminal_kill_pane
  terminal_kill_window
  terminal_pane_alive
  terminal_spawn_worker_layout
)
(
  export CEKERNEL_TERMINAL=tmux
  source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"
  ALL_DEFINED=true
  MISSING=""
  for fn in "${REQUIRED_FUNCTIONS[@]}"; do
    if ! declare -f "$fn" >/dev/null 2>&1; then
      ALL_DEFINED=false
      MISSING="${MISSING} ${fn}"
    fi
  done
  if $ALL_DEFINED; then
    echo "  PASS: tmux backend defines all required functions"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: tmux backend missing functions:${MISSING}"
    ((TESTS_FAILED++)) || true
  fi
)

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
