#!/usr/bin/env bash
# test-watch-env-backend.sh — watch.sh resolves backend from env profile
#
# Regression test for #182: watch.sh must source load-env.sh so that
# CEKERNEL_BACKEND is resolved from the env profile (e.g., headless.env).
# Without load-env.sh, it falls back to wezterm and causes false crash detection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch env backend resolution (issue #182)"

export CEKERNEL_SESSION_ID="test-watch-env-backend-0001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

ISSUE_NUMBER=182
SLEEP_PID=""
RESULT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

# Setup: create temp env directory with test profile
TEMP_ENV_DIR=$(mktemp -d)
echo "CEKERNEL_BACKEND=headless" > "${TEMP_ENV_DIR}/test-headless.env"

cleanup() {
  # Kill the sleep process
  if [[ -n "$SLEEP_PID" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  rm -rf "$CEKERNEL_IPC_DIR"
  rm -rf "$TEMP_ENV_DIR"
  rm -f "$RESULT_FILE" "$STDERR_FILE"
}
trap cleanup EXIT

mkdir -p "$CEKERNEL_IPC_DIR/logs"

# Create a live process and record its PID in a handle file
sleep 300 &
SLEEP_PID=$!
echo "$SLEEP_PID" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE_NUMBER}.worker"

# Write RUNNING state
worker_state_write "$ISSUE_NUMBER" RUNNING "phase1:implement"

# Set env profile to test-headless (do NOT set CEKERNEL_BACKEND directly)
# load-env.sh supports _CEKERNEL_PLUGIN_ENVS_DIR override for testing
export CEKERNEL_ENV=test-headless
export _CEKERNEL_PLUGIN_ENVS_DIR="$TEMP_ENV_DIR"
unset CEKERNEL_BACKEND 2>/dev/null || true

export CEKERNEL_POLL_INTERVAL=1
export CEKERNEL_WORKER_TIMEOUT=10

# Start watch in background
bash "${CEKERNEL_DIR}/scripts/orchestrator/watch.sh" "$ISSUE_NUMBER" > "$RESULT_FILE" 2>"$STDERR_FILE" &
WATCH_PID=$!

# After 2 seconds, write TERMINATED state to let watch complete via state fallback
sleep 2
worker_state_write "$ISSUE_NUMBER" TERMINATED "merged:#999"

# Wait for watch to complete (up to 15 seconds)
WATCH_DONE=0
for _ in $(seq 1 150); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

if [[ "$WATCH_DONE" -eq 0 ]]; then
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  echo "  FAIL: watch timed out"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  report_results
  exit "$TESTS_FAILED"
fi

wait "$WATCH_PID" 2>/dev/null || true

RESULT=$(cat "$RESULT_FILE")

# Key assertion: result should NOT be "crashed"
# If load-env.sh is not sourced, watch.sh falls back to wezterm backend
# and the live PID is not found as a wezterm pane -> false crash detection
RESULT_VALUE=$(echo "$RESULT" | jq -r '.result')
assert_eq "No false crash (env profile backend resolved)" "merged:#999" "$RESULT_VALUE"

# Verify the status is detected via state fallback (not crash)
assert_match "Detected via state fallback" "detected-via-state-fallback" "$RESULT"

report_results
