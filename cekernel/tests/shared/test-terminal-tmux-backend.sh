#!/usr/bin/env bash
# test-terminal-tmux-backend.sh — Tests for tmux backend
#
# Mocks tmux commands and verifies backend function behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: terminal-tmux-backend"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-tmux-backend-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Load tmux backend ──
export CEKERNEL_TERMINAL=tmux
source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"

# ── Test 1: terminal_available — tmux exists ──
tmux() { return 0; }
export -f tmux
if terminal_available; then
  echo "  PASS: terminal_available returns 0 when tmux exists"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: terminal_available should return 0"
  ((TESTS_FAILED++)) || true
fi

# ── Test 2: terminal_available — tmux missing ──
unset -f tmux 2>/dev/null || true
OLD_PATH="$PATH"
PATH=""
if terminal_available; then
  echo "  FAIL: terminal_available should return 1 when tmux missing"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: terminal_available returns 1 when tmux missing"
  ((TESTS_PASSED++)) || true
fi
PATH="$OLD_PATH"

# ── Test 3: terminal_resolve_workspace — returns tmux session name ──
tmux() {
  if [[ "$1" == "display-message" ]]; then
    echo "my-session"
  fi
}
export -f tmux
RESULT=$(terminal_resolve_workspace)
assert_eq "resolve_workspace returns tmux session name" "my-session" "$RESULT"

# ── Test 4: terminal_spawn_window — creates new window ──
MOCK_LOG=$(mktemp)
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
  if [[ "$1" == "new-window" ]]; then
    echo "my-session:1.0"  # mock pane target
  fi
}
export -f tmux
RESULT=$(terminal_spawn_window "/tmp/test-cwd" "my-session")
assert_eq "spawn_window returns pane target" "my-session:1.0" "$RESULT"
LOGGED=$(cat "$MOCK_LOG")
assert_match "spawn_window passes -c for cwd" ".*-c /tmp/test-cwd.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 5: terminal_run_command — sends keys to pane ──
MOCK_LOG=$(mktemp)
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
}
export -f tmux
terminal_run_command "my-session:1.0" "echo hello"
LOGGED=$(cat "$MOCK_LOG")
assert_match "run_command uses send-keys" ".*send-keys.*" "$LOGGED"
assert_match "run_command targets correct pane" ".*-t my-session:1.0.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 6: terminal_split_pane — bottom split ──
MOCK_LOG=$(mktemp)
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
  if [[ "$1" == "split-window" ]]; then
    echo "my-session:1.1"
  fi
}
export -f tmux
RESULT=$(terminal_split_pane bottom 25 "my-session:1.0" "/tmp/cwd" "watch git log")
assert_match "split_pane uses -v for bottom" ".*-v.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 7: terminal_split_pane — right split ──
MOCK_LOG=$(mktemp)
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
  if [[ "$1" == "split-window" ]]; then
    echo "my-session:1.2"
  fi
}
export -f tmux
RESULT=$(terminal_split_pane right 40 "my-session:1.0" "/tmp/cwd")
LOGGED=$(cat "$MOCK_LOG")
assert_match "split_pane uses -h for right" ".*-h.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 8: terminal_kill_pane ──
MOCK_LOG=$(mktemp)
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
}
export -f tmux
terminal_kill_pane "my-session:1.0"
LOGGED=$(cat "$MOCK_LOG")
assert_match "kill_pane uses kill-pane -t" ".*kill-pane.*-t my-session:1.0.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 9: terminal_kill_window ──
MOCK_LOG=$(mktemp)
tmux() {
  echo "tmux $*" >> "$MOCK_LOG"
}
export -f tmux
terminal_kill_window "my-session:1.0"
LOGGED=$(cat "$MOCK_LOG")
assert_match "kill_window uses kill-window" ".*kill-window.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 10: terminal_pane_alive — alive ──
tmux() {
  if [[ "$1" == "has-session" || "$1" == "display-message" ]]; then
    return 0
  fi
  if [[ "$1" == "list-panes" ]]; then
    echo "my-session:1.0"
    return 0
  fi
}
export -f tmux
if terminal_pane_alive "my-session:1.0"; then
  echo "  PASS: pane_alive returns 0 for existing pane"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: pane_alive should return 0 for existing pane"
  ((TESTS_FAILED++)) || true
fi

# ── Test 11: terminal_pane_alive — dead ──
tmux() {
  if [[ "$1" == "list-panes" ]]; then
    return 1
  fi
  return 1
}
export -f tmux
if terminal_pane_alive "nonexistent:99.0"; then
  echo "  FAIL: pane_alive should return 1 for dead pane"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: pane_alive returns 1 for dead pane"
  ((TESTS_PASSED++)) || true
fi

# ── Cleanup ──
unset -f tmux 2>/dev/null || true
rm -rf "$CEKERNEL_IPC_DIR"

report_results
