#!/usr/bin/env bash
# test-load-env-integration.sh — Verify orchestrator scripts source load-env.sh
#
# Regression test for #373: orchestrator scripts must source load-env.sh
# before session-id.sh so that CEKERNEL_VAR_DIR from the user profile is
# respected (instead of falling back to the hardcoded default).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: load-env integration (orchestrator scripts)"

# ── Setup: create a mock user profile with custom CEKERNEL_VAR_DIR ──
TEST_TMPDIR=$(mktemp -d)
MOCK_USER_ENVS="${TEST_TMPDIR}/user-envs"
MOCK_VAR_DIR="${TEST_TMPDIR}/custom-var"
mkdir -p "$MOCK_USER_ENVS" "$MOCK_VAR_DIR/ipc"

cat > "${MOCK_USER_ENVS}/default.env" <<ENVFILE
CEKERNEL_VAR_DIR=${MOCK_VAR_DIR}
ENVFILE

cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# Create a session with a FIFO inside the custom var dir
TEST_SESSION="test-loadenv-00000001"
mkdir -p "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}"
mkfifo "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/worker-99"

# ── Helper: run a script with CEKERNEL_VAR_DIR unset, user profile pointing to custom dir ──
# This simulates the real-world scenario from #373: the script is invoked
# without CEKERNEL_VAR_DIR in the environment, and must discover it from
# the user profile via load-env.sh.
run_with_user_profile() {
  local script="$1"
  shift
  env -u CEKERNEL_VAR_DIR \
    CEKERNEL_SESSION_ID="$TEST_SESSION" \
    CEKERNEL_ENV=default \
    _CEKERNEL_USER_ENVS_DIR="$MOCK_USER_ENVS" \
    _CEKERNEL_PROJECT_ENVS_DIR="${TEST_TMPDIR}/nonexistent-project" \
    _CEKERNEL_PLUGIN_ENVS_DIR="${TEST_TMPDIR}/nonexistent-plugin" \
    bash "$script" "$@" 2>&1
}

# ── Test 1: process-status.sh uses CEKERNEL_VAR_DIR from user profile ──
OUTPUT=$(run_with_user_profile "${CEKERNEL_DIR}/scripts/orchestrator/process-status.sh" || true)
assert_match "process-status.sh finds worker via user profile CEKERNEL_VAR_DIR" '"issue":99' "$OUTPUT"

# ── Test 2: process-status.sh does NOT report "No active session" ──
# If load-env.sh is not sourced, CEKERNEL_VAR_DIR defaults to $HOME/.local/var/cekernel
# and the session dir won't be found.
NO_SESSION_MSG=$(echo "$OUTPUT" | grep -c "No active session" || true)
assert_eq "process-status.sh does not report missing session" "0" "$NO_SESSION_MSG"

# ── Test 3: health-check.sh uses CEKERNEL_VAR_DIR from user profile ──
# health-check.sh with an issue number should find the FIFO in the custom var dir.
# Without load-env.sh, it would look in $HOME/.local/var/cekernel and report "completed"
# (because the FIFO wouldn't be found at the wrong path).
HC_OUTPUT=$(run_with_user_profile "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 99 2>&1 || true)
# When load-env.sh works, health-check finds the FIFO and reports status (not "completed")
HC_COMPLETED=$(echo "$HC_OUTPUT" | grep -c '"status":"completed"' || true)
assert_eq "health-check.sh finds FIFO via user profile CEKERNEL_VAR_DIR" "0" "$HC_COMPLETED"

# ── Test 4: send-signal.sh uses CEKERNEL_VAR_DIR from user profile ──
SIG_OUTPUT=$(run_with_user_profile "${CEKERNEL_DIR}/scripts/orchestrator/send-signal.sh" 99 TERM 2>&1 || true)
SIG_NO_IPC=$(echo "$SIG_OUTPUT" | grep -c "IPC directory not found" || true)
assert_eq "send-signal.sh does not report missing IPC dir" "0" "$SIG_NO_IPC"
# Verify signal file was created in the correct location
assert_file_exists "send-signal.sh creates signal in custom var dir" \
  "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/worker-99.signal"

# ── Test 5: watch-logs.sh uses CEKERNEL_VAR_DIR from user profile ──
# Create a dummy log file to verify it looks in the right place.
# watch-logs.sh uses 'tail -f' which blocks, so run with a short timeout
# and check stderr for the "Watching" message (success) vs "No log directory" (failure).
mkdir -p "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/logs"
echo "test log" > "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/logs/worker-99.log"
WL_OUTPUT=$(timeout 2 bash -c '
  env -u CEKERNEL_VAR_DIR \
    CEKERNEL_SESSION_ID="'"$TEST_SESSION"'" \
    CEKERNEL_ENV=default \
    _CEKERNEL_USER_ENVS_DIR="'"$MOCK_USER_ENVS"'" \
    _CEKERNEL_PROJECT_ENVS_DIR="'"${TEST_TMPDIR}/nonexistent-project"'" \
    _CEKERNEL_PLUGIN_ENVS_DIR="'"${TEST_TMPDIR}/nonexistent-plugin"'" \
    bash "'"${CEKERNEL_DIR}/scripts/orchestrator/watch-logs.sh"'" 99
' 2>&1 || true)
WL_NO_DIR=$(echo "$WL_OUTPUT" | grep -c "No log directory found" || true)
assert_eq "watch-logs.sh does not report missing log dir" "0" "$WL_NO_DIR"

# ── Cleanup ──
rm -rf "$TEST_TMPDIR"

report_results
