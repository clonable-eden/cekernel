#!/usr/bin/env bash
# test-terminal-adapter.sh — Tests for terminal-adapter.sh
#
# Mocks WezTerm commands and verifies adapter function behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: terminal-adapter"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-terminal-adapter-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Load terminal-adapter.sh ──
source "${CEKERNEL_DIR}/scripts/shared/terminal-adapter.sh"

# ── Test 1: terminal_available — wezterm exists ──
wezterm() { return 0; }
export -f wezterm
if terminal_available; then
  echo "  PASS: terminal_available returns 0 when wezterm exists"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: terminal_available should return 0"
  ((TESTS_FAILED++)) || true
fi

# ── Test 2: terminal_available — wezterm missing ──
unset -f wezterm 2>/dev/null || true
# Temporarily empty PATH so command -v wezterm fails
OLD_PATH="$PATH"
PATH=""
if terminal_available; then
  echo "  FAIL: terminal_available should return 1 when wezterm missing"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: terminal_available returns 1 when wezterm missing"
  ((TESTS_PASSED++)) || true
fi
PATH="$OLD_PATH"

# ── Test 3: terminal_resolve_workspace — WEZTERM_PANE not set ──
unset WEZTERM_PANE 2>/dev/null || true
RESULT=$(terminal_resolve_workspace)
assert_eq "resolve_workspace: no WEZTERM_PANE returns empty" "" "$RESULT"

# ── Test 4: terminal_resolve_workspace — normal case ──
export WEZTERM_PANE=5
wezterm() {
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    cat <<'MOCK_JSON'
[
  {"pane_id": 3, "workspace": "default"},
  {"pane_id": 5, "workspace": "orchestrator-ws"},
  {"pane_id": 7, "workspace": "other-ws"}
]
MOCK_JSON
  fi
}
export -f wezterm
RESULT=$(terminal_resolve_workspace)
assert_eq "resolve_workspace: WEZTERM_PANE=5 returns orchestrator-ws" "orchestrator-ws" "$RESULT"

# ── Test 5: terminal_resolve_workspace — pane not found ──
export WEZTERM_PANE=999
RESULT=$(terminal_resolve_workspace)
assert_eq "resolve_workspace: WEZTERM_PANE=999 returns empty" "" "$RESULT"

# ── Test 6: terminal_spawn_window — with workspace ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "$*" >> "$MOCK_LOG"
  if [[ "$1" == "cli" && "$2" == "spawn" ]]; then
    echo "42"  # mock pane ID
  fi
}
export -f wezterm
RESULT=$(terminal_spawn_window "/tmp/test-cwd" "my-ws")
assert_eq "spawn_window returns pane ID" "42" "$RESULT"
LOGGED=$(cat "$MOCK_LOG")
assert_match "spawn_window passes workspace" ".*--workspace my-ws.*" "$LOGGED"
assert_match "spawn_window passes cwd" ".*--cwd /tmp/test-cwd.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 7: terminal_spawn_window — without workspace ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "$*" >> "$MOCK_LOG"
  if [[ "$1" == "cli" && "$2" == "spawn" ]]; then
    echo "43"
  fi
}
export -f wezterm
RESULT=$(terminal_spawn_window "/tmp/test-cwd" "")
assert_eq "spawn_window without workspace returns pane ID" "43" "$RESULT"
LOGGED=$(cat "$MOCK_LOG")
# Verify --workspace argument is not present
if echo "$LOGGED" | grep -q -- "--workspace"; then
  echo "  FAIL: spawn_window should not pass --workspace when empty"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: spawn_window omits --workspace when empty"
  ((TESTS_PASSED++)) || true
fi
rm -f "$MOCK_LOG"

# ── Test 8: terminal_run_command — send text + Enter ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "wezterm $*" >> "$MOCK_LOG"
}
export -f wezterm
terminal_run_command "10" "echo hello"
CALLS=$(cat "$MOCK_LOG")
CALL_COUNT=$(wc -l < "$MOCK_LOG" | tr -d ' ')
assert_eq "run_command makes 2 wezterm calls" "2" "$CALL_COUNT"
assert_match "run_command first call sends text" ".*send-text.*--pane-id 10.*" "$(head -1 "$MOCK_LOG")"
rm -f "$MOCK_LOG"

# ── Test 9: terminal_split_pane — bottom split with command ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "$*" >> "$MOCK_LOG"
}
export -f wezterm
terminal_split_pane bottom 25 "10" "/tmp/cwd" watch -n3 git log
LOGGED=$(cat "$MOCK_LOG")
assert_match "split_pane passes --bottom" ".*--bottom.*" "$LOGGED"
assert_match "split_pane passes --percent 25" ".*--percent 25.*" "$LOGGED"
assert_match "split_pane passes --pane-id" ".*--pane-id 10.*" "$LOGGED"
assert_match "split_pane passes command after --" ".*-- watch.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 10: terminal_split_pane — right split without command ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "$*" >> "$MOCK_LOG"
}
export -f wezterm
terminal_split_pane right 40 "10" "/tmp/cwd"
LOGGED=$(cat "$MOCK_LOG")
assert_match "split_pane right passes --right" ".*--right.*" "$LOGGED"
# Verify -- is not present
if echo "$LOGGED" | grep -q " -- "; then
  echo "  FAIL: split_pane without command should not pass --"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: split_pane without command omits --"
  ((TESTS_PASSED++)) || true
fi
rm -f "$MOCK_LOG"

# ── Test 11: terminal_kill_pane ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "$*" >> "$MOCK_LOG"
}
export -f wezterm
terminal_kill_pane "10"
LOGGED=$(cat "$MOCK_LOG")
assert_match "kill_pane passes pane ID" ".*kill-pane.*--pane-id 10.*" "$LOGGED"
rm -f "$MOCK_LOG"

# ── Test 12: terminal_kill_window — kill all panes in same window ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "wezterm $*" >> "$MOCK_LOG"
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    cat <<'MOCK_JSON'
[
  {"pane_id": 10, "window_id": 1},
  {"pane_id": 11, "window_id": 1},
  {"pane_id": 12, "window_id": 1},
  {"pane_id": 20, "window_id": 2}
]
MOCK_JSON
  fi
}
export -f wezterm
terminal_kill_window "10" 2>/dev/null
KILL_COUNT=$(grep -c "kill-pane" "$MOCK_LOG")
assert_eq "kill_window kills 3 panes in same window" "3" "$KILL_COUNT"
# Verify pane 20 from window 2 is not killed
if grep -q "pane-id 20" "$MOCK_LOG"; then
  echo "  FAIL: kill_window should not kill panes in other windows"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: kill_window only kills panes in same window"
  ((TESTS_PASSED++)) || true
fi
rm -f "$MOCK_LOG"

# ── Test 13: terminal_pane_alive — alive (WezTerm JSON with spaces) ──
wezterm() {
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    cat <<'MOCK_JSON'
[
  {"pane_id": 10, "window_id": 1, "workspace": "default"},
  {"pane_id": 20, "window_id": 1, "workspace": "default"}
]
MOCK_JSON
  fi
}
export -f wezterm
if terminal_pane_alive "10"; then
  echo "  PASS: pane_alive returns 0 for existing pane"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: pane_alive should return 0 for existing pane"
  ((TESTS_FAILED++)) || true
fi

# ── Test 14: terminal_pane_alive — dead ──
if terminal_pane_alive "999"; then
  echo "  FAIL: pane_alive should return 1 for dead pane"
  ((TESTS_FAILED++)) || true
else
  echo "  PASS: pane_alive returns 1 for dead pane"
  ((TESTS_PASSED++)) || true
fi

# ── Test 15: terminal_pane_alive — compact JSON (no spaces) ──
wezterm() {
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    echo '[{"pane_id":10},{"pane_id":20}]'
  fi
}
export -f wezterm
if terminal_pane_alive "10"; then
  echo "  PASS: pane_alive handles compact JSON"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: pane_alive should handle compact JSON"
  ((TESTS_FAILED++)) || true
fi

# ── Cleanup ──
unset -f wezterm 2>/dev/null || true
unset WEZTERM_PANE 2>/dev/null || true
rm -rf "$CEKERNEL_IPC_DIR"

report_results
