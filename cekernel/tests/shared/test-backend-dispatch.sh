#!/usr/bin/env bash
# test-backend-dispatch.sh — Tests for backend dispatch in backend-adapter.sh
#
# Verifies that backend-adapter.sh selects the correct backend based on
# CEKERNEL_BACKEND env var (renamed from CEKERNEL_TERMINAL per ADR-0005).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: backend-dispatch"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-backend-dispatch-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Test 1: Default backend is wezterm ──
RESULT=$(unset CEKERNEL_BACKEND; bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' && echo \"\$CEKERNEL_ACTIVE_BACKEND\"" 2>/dev/null)
assert_eq "default CEKERNEL_ACTIVE_BACKEND is wezterm" "wezterm" "$RESULT"

# ── Test 2: CEKERNEL_BACKEND=wezterm selects wezterm backend ──
RESULT=$(CEKERNEL_BACKEND=wezterm bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' && echo \"\$CEKERNEL_ACTIVE_BACKEND\"" 2>/dev/null)
assert_eq "CEKERNEL_BACKEND=wezterm selects wezterm" "wezterm" "$RESULT"

# ── Test 3: CEKERNEL_BACKEND=tmux selects tmux backend ──
RESULT=$(CEKERNEL_BACKEND=tmux bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' && echo \"\$CEKERNEL_ACTIVE_BACKEND\"" 2>/dev/null)
assert_eq "CEKERNEL_BACKEND=tmux selects tmux" "tmux" "$RESULT"

# ── Test 4: CEKERNEL_BACKEND=headless selects headless backend ──
RESULT=$(CEKERNEL_BACKEND=headless bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh' && echo \"\$CEKERNEL_ACTIVE_BACKEND\"" 2>/dev/null)
assert_eq "CEKERNEL_BACKEND=headless selects headless" "headless" "$RESULT"

# ── Test 5: Unknown backend fails with error ──
if CEKERNEL_BACKEND=unknown_backend bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh'" 2>/dev/null; then
  echo "  FAIL: unknown backend should cause an error"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: unknown backend causes error"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 6: wezterm backend defines all 4 external API functions ──
REQUIRED_FUNCTIONS=(
  backend_available
  backend_spawn_worker
  backend_worker_alive
  backend_kill_worker
)
FUNC_CHECK=""
for fn in "${REQUIRED_FUNCTIONS[@]}"; do
  FUNC_CHECK="${FUNC_CHECK}declare -f ${fn} >/dev/null 2>&1 || echo ${fn}; "
done
MISSING=$(CEKERNEL_BACKEND=wezterm bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh'; ${FUNC_CHECK}" 2>/dev/null)
if [[ -z "$MISSING" ]]; then
  echo "  PASS: wezterm backend defines all 4 external API functions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: wezterm backend missing functions: ${MISSING}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: tmux backend defines all 4 external API functions ──
MISSING=$(CEKERNEL_BACKEND=tmux bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh'; ${FUNC_CHECK}" 2>/dev/null)
if [[ -z "$MISSING" ]]; then
  echo "  PASS: tmux backend defines all 4 external API functions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: tmux backend missing functions: ${MISSING}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: headless backend defines all 4 external API functions ──
MISSING=$(CEKERNEL_BACKEND=headless bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh'; ${FUNC_CHECK}" 2>/dev/null)
if [[ -z "$MISSING" ]]; then
  echo "  PASS: headless backend defines all 4 external API functions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: headless backend missing functions: ${MISSING}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: Old terminal_* functions are NOT defined (clean break) ──
OLD_FUNCTIONS=(
  terminal_available
  terminal_spawn_window
  terminal_run_command
  terminal_split_pane
  terminal_kill_pane
  terminal_kill_window
  terminal_pane_alive
  terminal_resolve_workspace
  terminal_spawn_worker_layout
)
OLD_CHECK=""
for fn in "${OLD_FUNCTIONS[@]}"; do
  OLD_CHECK="${OLD_CHECK}declare -f ${fn} >/dev/null 2>&1 && echo ${fn}; "
done
FOUND=$(CEKERNEL_BACKEND=wezterm bash -c "source '${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh'; ${OLD_CHECK}" 2>/dev/null || true)
if [[ -z "$FOUND" ]]; then
  echo "  PASS: No old terminal_* functions leaked into external API"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Old terminal_* functions still defined: ${FOUND}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
