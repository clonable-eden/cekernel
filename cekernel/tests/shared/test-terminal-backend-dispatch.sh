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
# Source in subshell to avoid polluting current shell with functions.
# Run as separate bash process to test unset CEKERNEL_TERMINAL.
RESULT=$(unset CEKERNEL_TERMINAL; bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh' && echo \"\$CEKERNEL_TERMINAL_BACKEND\"" 2>/dev/null)
assert_eq "default CEKERNEL_TERMINAL_BACKEND is wezterm" "wezterm" "$RESULT"

# ── Test 2: CEKERNEL_TERMINAL=wezterm selects wezterm backend ──
RESULT=$(CEKERNEL_TERMINAL=wezterm bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh' && echo \"\$CEKERNEL_TERMINAL_BACKEND\"" 2>/dev/null)
assert_eq "CEKERNEL_TERMINAL=wezterm selects wezterm" "wezterm" "$RESULT"

# ── Test 3: CEKERNEL_TERMINAL=tmux selects tmux backend ──
RESULT=$(CEKERNEL_TERMINAL=tmux bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh' && echo \"\$CEKERNEL_TERMINAL_BACKEND\"" 2>/dev/null)
assert_eq "CEKERNEL_TERMINAL=tmux selects tmux" "tmux" "$RESULT"

# ── Test 4: Unknown backend fails with error ──
if CEKERNEL_TERMINAL=unknown_terminal bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh'" 2>/dev/null; then
  echo "  FAIL: unknown backend should cause an error"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: unknown backend causes error"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 5: wezterm backend provides terminal_available function ──
RESULT=$(CEKERNEL_TERMINAL=wezterm bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh' && declare -f terminal_available >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)
assert_eq "wezterm backend defines terminal_available" "yes" "$RESULT"

# ── Test 6: tmux backend provides terminal_available function ──
RESULT=$(CEKERNEL_TERMINAL=tmux bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh' && declare -f terminal_available >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)
assert_eq "tmux backend defines terminal_available" "yes" "$RESULT"

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
FUNC_CHECK=""
for fn in "${REQUIRED_FUNCTIONS[@]}"; do
  FUNC_CHECK="${FUNC_CHECK}declare -f ${fn} >/dev/null 2>&1 || echo ${fn}; "
done
MISSING=$(CEKERNEL_TERMINAL=tmux bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh'; ${FUNC_CHECK}" 2>/dev/null)
if [[ -z "$MISSING" ]]; then
  echo "  PASS: tmux backend defines all required functions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: tmux backend missing functions: ${MISSING}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: wezterm backend provides all required functions ──
MISSING=$(CEKERNEL_TERMINAL=wezterm bash -c "source '${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh'; ${FUNC_CHECK}" 2>/dev/null)
if [[ -z "$MISSING" ]]; then
  echo "  PASS: wezterm backend defines all required functions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: wezterm backend missing functions: ${MISSING}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
