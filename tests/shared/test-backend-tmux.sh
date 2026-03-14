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

# ── Test 1: backend_available — tmux exists and server reachable ──
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
SPLIT_CALL_COUNT=0
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
    SPLIT_CALL_COUNT=$((SPLIT_CALL_COUNT + 1))
    if [[ "$SPLIT_CALL_COUNT" -eq 1 ]]; then
      echo "my-session:1.1"  # right pane
    else
      echo "my-session:1.2"  # bottom pane
    fi
  fi
}
export -f tmux

ISSUE="400"
WORKTREE="/tmp/test-worktree"
backend_spawn_worker "$ISSUE" "worker" "$WORKTREE" "test prompt" "worker"

HANDLE_FILE="${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
assert_file_exists "Handle file created after spawn" "$HANDLE_FILE"

HANDLE=$(cat "$HANDLE_FILE")
assert_eq "Handle contains pane target" "my-session:1.0" "$HANDLE"

# ── Test 3b: backend_spawn_worker — sends watch command to right pane ──
LOGGED=$(cat "$MOCK_LOG")
assert_match "watch command sent to right pane" ".*send-keys -t my-session:1.1 watch -n 5.*" "$LOGGED"
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

# ── Test 9: Apostrophe in prompt is safely passed via file ──
MOCK_LOG=$(mktemp)
SPLIT_CALL_COUNT=0
export TMUX="/tmp/tmux-501/default,12345,0"
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
  if [[ "$1" == "new-window" ]]; then echo "my-session:1.0"; fi
  if [[ "$1" == "display-message" ]]; then echo "my-session"; fi
  if [[ "$1" == "split-window" ]]; then
    SPLIT_CALL_COUNT=$((SPLIT_CALL_COUNT + 1))
    echo "my-session:1.$SPLIT_CALL_COUNT"
  fi
}
export -f tmux
backend_spawn_worker "410" "worker" "$WORKTREE" "Read the target repository's CLAUDE.md" "worker"

# Prompt file should contain the exact prompt (including apostrophe)
PROMPT_CONTENT=$(cat "${CEKERNEL_IPC_DIR}/prompt-410.txt")
assert_eq "apostrophe preserved in prompt file" "Read the target repository's CLAUDE.md" "$PROMPT_CONTENT"

# send-keys should only reference the runner script, not the raw prompt
LOGGED=$(cat "$MOCK_LOG")
RUNNER_LINE=$(echo "$LOGGED" | grep "send-keys" | grep "run-410.sh")
if [[ -n "$RUNNER_LINE" ]]; then
  echo "  PASS: send-keys references runner script (no raw prompt escaping needed)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: send-keys should reference runner script"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "$MOCK_LOG"

# ── Test 10: Runner script contains unset CLAUDECODE ──
MOCK_LOG=$(mktemp)
SPLIT_CALL_COUNT=0
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
  if [[ "$1" == "new-window" ]]; then echo "my-session:1.0"; fi
  if [[ "$1" == "display-message" ]]; then echo "my-session"; fi
  if [[ "$1" == "split-window" ]]; then
    SPLIT_CALL_COUNT=$((SPLIT_CALL_COUNT + 1))
    echo "my-session:1.$SPLIT_CALL_COUNT"
  fi
}
export -f tmux
backend_spawn_worker "411" "worker" "$WORKTREE" "test prompt" "worker"
RUNNER_CONTENT=$(cat "${CEKERNEL_IPC_DIR}/run-411.sh")
assert_match "runner script unsets CLAUDECODE" "unset CLAUDECODE" "$RUNNER_CONTENT"
rm -f "$MOCK_LOG"

# ── Test 11: Runner script uses exec claude directly (no script command) ──
MOCK_LOG=$(mktemp)
SPLIT_CALL_COUNT=0
export TMUX="/tmp/tmux-501/default,12345,0"
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
  if [[ "$1" == "new-window" ]]; then echo "my-session:1.0"; fi
  if [[ "$1" == "display-message" ]]; then echo "my-session"; fi
  if [[ "$1" == "split-window" ]]; then
    SPLIT_CALL_COUNT=$((SPLIT_CALL_COUNT + 1))
    echo "my-session:1.$SPLIT_CALL_COUNT"
  fi
}
export -f tmux
backend_spawn_worker "412" "worker" "$WORKTREE" "test prompt" "worker"
RUNNER_CONTENT=$(cat "${CEKERNEL_IPC_DIR}/run-412.sh")
assert_match "runner script uses exec claude" "exec claude -p --agent" "$RUNNER_CONTENT"
if echo "$RUNNER_CONTENT" | grep -q "exec script "; then
  echo "  FAIL: runner script should not use script command"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: runner script does not use script command"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi
rm -f "$MOCK_LOG"

# ── Cleanup ──
unset -f tmux 2>/dev/null || true
unset TMUX 2>/dev/null || true
rm -rf "$CEKERNEL_IPC_DIR"

report_results
