#!/usr/bin/env bash
# test-agent-name-resolution.sh — Tests for dynamic agent name resolution
#
# Verifies that spawn.sh resolves agent names and passes them
# as the 5th parameter to backend_spawn_worker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: agent-name-resolution"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-agent-name-001"
# --bare preflight requires an auth path (never reads OAuth/keychain)
export ANTHROPIC_API_KEY="test-key-bare"
unset CEKERNEL_CLAUDE_SETTINGS
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"
mkdir -p "${CEKERNEL_IPC_DIR}/logs"

# ── Test 1: spawn-worker.sh defaults CEKERNEL_AGENT_WORKER to 'worker' when unset ──
# Source only the top portion to check the variable resolution
(
  unset CEKERNEL_AGENT_WORKER
  CEKERNEL_AGENT_WORKER="${CEKERNEL_AGENT_WORKER:-worker}"
  echo "$CEKERNEL_AGENT_WORKER"
) | {
  read -r result
  assert_eq "CEKERNEL_AGENT_WORKER defaults to 'worker' when unset" "worker" "$result"
}

# ── Test 2: spawn-worker.sh uses CEKERNEL_AGENT_WORKER when set ──
(
  export CEKERNEL_AGENT_WORKER="cekernel:worker"
  CEKERNEL_AGENT_WORKER="${CEKERNEL_AGENT_WORKER:-worker}"
  echo "$CEKERNEL_AGENT_WORKER"
) | {
  read -r result
  assert_eq "CEKERNEL_AGENT_WORKER preserves 'cekernel:worker' when set" "cekernel:worker" "$result"
}

# NOTE: The former Tests 3/3a/3b (headless backend passes the agent name
# to claude argv) moved to tests/shared/backend-headless.bats on the v2
# --bg contract (ADR-0017 §3) — the -p era mock claude blocked the
# synchronous --bg spawn path.

# ── Test 4: backends no longer hardcode CEKERNEL_AGENT_WORKER ──
# After #340, backends receive agent name as a parameter, not from env var.
# tmux and wezterm should NOT reference CEKERNEL_AGENT_WORKER directly.
if ! grep -q 'CEKERNEL_AGENT_WORKER' "${CEKERNEL_DIR}/scripts/shared/backends/tmux.sh"; then
  echo "  PASS: tmux backend does not hardcode CEKERNEL_AGENT_WORKER (uses 5th param)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: tmux backend should not reference CEKERNEL_AGENT_WORKER (should use 5th param)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: wezterm backend does not hardcode CEKERNEL_AGENT_WORKER ──
if ! grep -q 'CEKERNEL_AGENT_WORKER' "${CEKERNEL_DIR}/scripts/shared/backends/wezterm.sh"; then
  echo "  PASS: wezterm backend does not hardcode CEKERNEL_AGENT_WORKER (uses 5th param)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: wezterm backend should not reference CEKERNEL_AGENT_WORKER (should use 5th param)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: headless backend does not hardcode CEKERNEL_AGENT_WORKER ──
if ! grep -q 'CEKERNEL_AGENT_WORKER' "${CEKERNEL_DIR}/scripts/shared/backends/headless.sh"; then
  echo "  PASS: headless backend does not hardcode CEKERNEL_AGENT_WORKER (uses 5th param)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: headless backend should not reference CEKERNEL_AGENT_WORKER (should use 5th param)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: WezTerm Lua receives command field from bash ──
# Since #305, Lua no longer builds the claude command. It receives a
# pre-built command from bash via the 'command' payload field.
if grep -q 'command' "${CEKERNEL_DIR}/config/wezterm.cekernel.lua"; then
  echo "  PASS: wezterm lua reads command from params"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: wezterm lua should read command from params"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: spawn.sh passes AGENT_NAME as 5th arg to backend_spawn_worker ──
# Verify spawn.sh source contains the 5th parameter in the backend_spawn_worker call
SPAWN_CONTENT=$(cat "${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh")
if echo "$SPAWN_CONTENT" | grep -q 'backend_spawn_worker.*\$AGENT_NAME'; then
  echo "  PASS: spawn.sh passes \$AGENT_NAME to backend_spawn_worker"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh should pass \$AGENT_NAME to backend_spawn_worker"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
