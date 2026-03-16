#!/usr/bin/env bash
# test-backend-headless.sh — Tests for headless backend
#
# Verifies headless backend behavior: process spawning, alive check, kill.
# Uses mock commands to avoid actually launching claude.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: backend-headless"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-headless-backend-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Load headless backend ──
export CEKERNEL_BACKEND=headless
source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

# ── Test 1: backend_available — always returns 0 ──
if backend_available; then
  echo "  PASS: backend_available returns 0 (headless always available)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: backend_available should return 0 for headless"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: backend_spawn_worker — creates handle file with PID ──
# Create a mock claude command that sleeps
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP" "$CEKERNEL_IPC_DIR" 2>/dev/null || true' EXIT

MOCK_BIN="${TEST_TMP}/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "${MOCK_BIN}/claude" <<'MOCK_SCRIPT'
#!/usr/bin/env bash
# Mock claude that sleeps until killed
sleep 300
MOCK_SCRIPT
chmod +x "${MOCK_BIN}/claude"

OLD_PATH="$PATH"
export PATH="${MOCK_BIN}:${PATH}"

ISSUE="500"
WORKTREE="${TEST_TMP}/worktree"
mkdir -p "$WORKTREE"
# Create .cekernel-env required by headless backend (always present in production)
touch "${WORKTREE}/.cekernel-env"

backend_spawn_worker "$ISSUE" "worker" "$WORKTREE" "test prompt" "worker"

HANDLE_FILE="${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
assert_file_exists "Handle file created after spawn" "$HANDLE_FILE"

# Handle file should contain a numeric PID
PID=$(cat "$HANDLE_FILE")
if [[ "$PID" =~ ^[0-9]+$ ]]; then
  echo "  PASS: Handle file contains numeric PID ($PID)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Handle file should contain numeric PID, got: $PID"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: backend_get_pid — returns PID from handle file ──
GOT_PID=$(backend_get_pid "$ISSUE" "worker")
assert_eq "backend_get_pid returns handle PID" "$PID" "$GOT_PID"

# ── Test 4: backend_get_pid — fails for non-existent handle ──
EXIT_CODE=0
backend_get_pid "99999" "worker" 2>/dev/null || EXIT_CODE=$?
assert_eq "backend_get_pid fails for non-existent handle" "1" "$EXIT_CODE"

# ── Test 5: backend_worker_alive — returns 0 for running process ──
# Give it a moment to start
sleep 0.2
if backend_worker_alive "$ISSUE"; then
  echo "  PASS: backend_worker_alive returns 0 for running process"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: backend_worker_alive should return 0 for running process"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: backend_kill_worker — terminates the process ──
backend_kill_worker "$ISSUE"
sleep 0.5
# Wait for process to fully exit
wait 2>/dev/null || true

if backend_worker_alive "$ISSUE"; then
  echo "  FAIL: backend_worker_alive should return 1 after kill"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: backend_worker_alive returns 1 after kill"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 7: backend_worker_alive — returns 1 for non-existent handle ──
if backend_worker_alive "99999"; then
  echo "  FAIL: backend_worker_alive should return 1 for non-existent handle"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: backend_worker_alive returns 1 for non-existent handle"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 8: backend_kill_worker — no error for non-existent handle ──
EXIT_CODE=0
backend_kill_worker "99999" 2>/dev/null || EXIT_CODE=$?
assert_eq "kill_worker for non-existent handle exits cleanly" "0" "$EXIT_CODE"

# ── Test 9: Second worker spawn creates handle file ──
ISSUE2="501"
backend_spawn_worker "$ISSUE2" "worker" "$WORKTREE" "test prompt 2" "worker"

# (WORKTREE already has .cekernel-env from setup above)
sleep 0.2

# Verify handle file exists
HANDLE_FILE2="${CEKERNEL_IPC_DIR}/handle-${ISSUE2}.worker"
assert_file_exists "Handle file created for second worker" "$HANDLE_FILE2"

# Clean up process
backend_kill_worker "$ISSUE2" 2>/dev/null || true
sleep 0.2

# ── Test 10: headless backend sources .cekernel-env from worktree ──
# Verify that the spawned process inherits PATH via .cekernel-env sourcing.
# .cekernel-env writes a marker file when sourced — detectable from outside.
ISSUE_ENV="502"
WORKTREE_ENV="${TEST_TMP}/worktree-env"
mkdir -p "$WORKTREE_ENV"
ENV_MARKER="${TEST_TMP}/env-sourced.marker"
cat > "${WORKTREE_ENV}/.cekernel-env" <<ENVEOF
touch '${ENV_MARKER}'
ENVEOF

backend_spawn_worker "$ISSUE_ENV" "worker" "$WORKTREE_ENV" "test prompt" "worker"
sleep 0.5

if [[ -f "$ENV_MARKER" ]]; then
  echo "  PASS: .cekernel-env sourced by headless backend"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: .cekernel-env was not sourced by headless backend"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

backend_kill_worker "$ISSUE_ENV" 2>/dev/null || true
sleep 0.2

# ── Restore PATH ──
PATH="$OLD_PATH"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
