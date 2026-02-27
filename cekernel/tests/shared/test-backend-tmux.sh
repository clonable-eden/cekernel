#!/usr/bin/env bash
# test-backend-tmux.sh — Tests for tmux backend (ADR-0005 API)
#
# Tests the 4 external API functions using mocked tmux commands.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: backend-tmux"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-tmux-backend-002"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Load tmux backend ──
export CEKERNEL_BACKEND=tmux
source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

# ── Test 1: backend_available — tmux exists ──
tmux() { return 0; }
export -f tmux
if backend_available; then
  echo "  PASS: backend_available returns 0 when tmux exists"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: backend_available should return 0"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: backend_available — tmux missing ──
unset -f tmux 2>/dev/null || true
OLD_PATH="$PATH"
PATH=""
if backend_available; then
  echo "  FAIL: backend_available should return 1 when tmux missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: backend_available returns 1 when tmux missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi
PATH="$OLD_PATH"

# ── Test 3: backend_spawn_worker — spawns window and saves handle ──
MOCK_LOG=$(mktemp)
export TMUX="/tmp/tmux-501/default,12345,0"
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
  if [[ "$1" == "new-window" ]]; then
    echo "my-session:1.0"  # mock pane target
  fi
  if [[ "$1" == "display-message" ]]; then
    echo "my-session"
  fi
  if [[ "$1" == "split-window" ]]; then
    echo "my-session:1.1"
  fi
}
export -f tmux

ISSUE="400"
WORKTREE="/tmp/test-worktree"
backend_spawn_worker "$ISSUE" "$WORKTREE" "test prompt"

HANDLE_FILE="${CEKERNEL_IPC_DIR}/handle-${ISSUE}"
assert_file_exists "Handle file created after spawn" "$HANDLE_FILE"

HANDLE=$(cat "$HANDLE_FILE")
assert_eq "Handle contains pane target" "my-session:1.0" "$HANDLE"
rm -f "$MOCK_LOG"

# ── Test 4: backend_worker_alive — alive pane ──
tmux() {
  if [[ "$1" == "list-panes" ]]; then
    echo "my-session:1.0"
    return 0
  fi
  return 0
}
export -f tmux
if backend_worker_alive "$ISSUE"; then
  echo "  PASS: backend_worker_alive returns 0 for existing pane"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: backend_worker_alive should return 0 for existing pane"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: backend_worker_alive — dead pane ──
tmux() {
  if [[ "$1" == "list-panes" ]]; then
    return 1
  fi
  return 1
}
export -f tmux
if backend_worker_alive "$ISSUE"; then
  echo "  FAIL: backend_worker_alive should return 1 for dead pane"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: backend_worker_alive returns 1 for dead pane"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 6: backend_worker_alive — no handle file ──
if backend_worker_alive "99999"; then
  echo "  FAIL: backend_worker_alive should return 1 for missing handle"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: backend_worker_alive returns 1 for missing handle"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 7: backend_kill_worker — kills window ──
MOCK_LOG=$(mktemp)
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
}
export -f tmux
backend_kill_worker "$ISSUE" 2>/dev/null
LOGGED=$(cat "$MOCK_LOG")
assert_match "kill_worker uses kill-window" ".*kill-window.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 8: backend_kill_worker — no error for missing handle ──
EXIT_CODE=0
backend_kill_worker "99999" 2>/dev/null || EXIT_CODE=$?
assert_eq "kill_worker for missing handle exits cleanly" "0" "$EXIT_CODE"

# ── Cleanup ──
unset -f tmux 2>/dev/null || true
unset TMUX 2>/dev/null || true
rm -rf "$CEKERNEL_IPC_DIR"

report_results
