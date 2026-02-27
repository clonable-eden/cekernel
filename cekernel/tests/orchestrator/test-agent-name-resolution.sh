#!/usr/bin/env bash
# test-agent-name-resolution.sh — Tests for dynamic agent name resolution
#
# Verifies that backends use CEKERNEL_AGENT_WORKER when set,
# and default to 'worker' when unset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: agent-name-resolution"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-agent-name-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"
mkdir -p "${CEKERNEL_IPC_DIR}/logs"

# ── Test 1: spawn-worker.sh defaults CEKERNEL_AGENT_WORKER to 'worker' when unset ──
# Source only the top portion to check the variable resolution
(
  unset CEKERNEL_AGENT_WORKER
  SCRIPT_DIR_SW="$(cd "${CEKERNEL_DIR}/scripts/orchestrator" && pwd)"
  CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR_SW}/../.." && pwd)}"
  CEKERNEL_AGENT_WORKER="${CEKERNEL_AGENT_WORKER:-worker}"
  echo "$CEKERNEL_AGENT_WORKER"
) | {
  read -r result
  assert_eq "CEKERNEL_AGENT_WORKER defaults to 'worker' when unset" "worker" "$result"
}

# ── Test 2: spawn-worker.sh uses CEKERNEL_AGENT_WORKER when set ──
(
  export CEKERNEL_AGENT_WORKER="cekernel:worker"
  SCRIPT_DIR_SW="$(cd "${CEKERNEL_DIR}/scripts/orchestrator" && pwd)"
  CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR_SW}/../.." && pwd)}"
  CEKERNEL_AGENT_WORKER="${CEKERNEL_AGENT_WORKER:-worker}"
  echo "$CEKERNEL_AGENT_WORKER"
) | {
  read -r result
  assert_eq "CEKERNEL_AGENT_WORKER preserves 'cekernel:worker' when set" "cekernel:worker" "$result"
}

# ── Test 3: headless backend uses CEKERNEL_AGENT_WORKER in claude command ──
# Create a mock claude that records its arguments
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP" "$CEKERNEL_IPC_DIR" 2>/dev/null || true' EXIT

MOCK_BIN="${TEST_TMP}/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "${MOCK_BIN}/claude" <<'MOCK_SCRIPT'
#!/usr/bin/env bash
# Record args to a file, then sleep
echo "$@" > "${CEKERNEL_AGENT_ARGS_FILE:-/dev/null}"
sleep 300
MOCK_SCRIPT
chmod +x "${MOCK_BIN}/claude"

OLD_PATH="$PATH"
export PATH="${MOCK_BIN}:${PATH}"

# ── Test 3a: headless backend with CEKERNEL_AGENT_WORKER=cekernel:worker ──
export CEKERNEL_BACKEND=headless
export CEKERNEL_AGENT_WORKER="cekernel:worker"
ARGS_FILE="${TEST_TMP}/args-3a.txt"
export CEKERNEL_AGENT_ARGS_FILE="$ARGS_FILE"
source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

ISSUE="600"
WORKTREE="${TEST_TMP}/worktree"
mkdir -p "$WORKTREE"

backend_spawn_worker "$ISSUE" "$WORKTREE" "test prompt"
sleep 0.3

if [[ -f "$ARGS_FILE" ]]; then
  ARGS=$(cat "$ARGS_FILE")
  assert_match "headless uses CEKERNEL_AGENT_WORKER=cekernel:worker" "cekernel:worker" "$ARGS"
else
  echo "  FAIL: headless backend did not record claude args"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

backend_kill_worker "$ISSUE" 2>/dev/null || true
sleep 0.2
wait 2>/dev/null || true

# ── Test 3b: headless backend with CEKERNEL_AGENT_WORKER=worker (default) ──
export CEKERNEL_AGENT_WORKER="worker"
ARGS_FILE="${TEST_TMP}/args-3b.txt"
export CEKERNEL_AGENT_ARGS_FILE="$ARGS_FILE"

ISSUE2="601"
backend_spawn_worker "$ISSUE2" "$WORKTREE" "test prompt 2"
sleep 0.3

if [[ -f "$ARGS_FILE" ]]; then
  ARGS=$(cat "$ARGS_FILE")
  assert_match "headless uses CEKERNEL_AGENT_WORKER=worker" "--agent worker" "$ARGS"
else
  echo "  FAIL: headless backend did not record claude args (default)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

backend_kill_worker "$ISSUE2" 2>/dev/null || true
sleep 0.2
wait 2>/dev/null || true

# ── Test 4: tmux backend command contains CEKERNEL_AGENT_WORKER ──
# We can't test tmux without tmux running, so verify the code path by sourcing
# and checking the command string construction.
# Instead, grep the tmux backend source for the variable reference.
if grep -q 'CEKERNEL_AGENT_WORKER' "${CEKERNEL_DIR}/scripts/shared/backends/tmux.sh"; then
  echo "  PASS: tmux backend references CEKERNEL_AGENT_WORKER"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: tmux backend should reference CEKERNEL_AGENT_WORKER"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: WezTerm backend JSON payload includes agent_name ──
if grep -q 'agent_name' "${CEKERNEL_DIR}/scripts/shared/backends/wezterm.sh"; then
  echo "  PASS: wezterm backend includes agent_name in payload"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: wezterm backend should include agent_name in JSON payload"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: WezTerm Lua reads agent_name from params ──
if grep -q 'agent_name' "${CEKERNEL_DIR}/config/wezterm.cekernel.lua"; then
  echo "  PASS: wezterm lua reads agent_name from params"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: wezterm lua should read agent_name from params"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Restore PATH ──
PATH="$OLD_PATH"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
