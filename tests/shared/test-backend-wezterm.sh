#!/usr/bin/env bash
# test-backend-wezterm.sh — Tests for WezTerm backend (ADR-0005 API)
#
# Tests the 4 external API functions and verifies internal functions
# are used correctly by backend_spawn_worker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: backend-wezterm"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-wezterm-backend-001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Load wezterm backend ──
export CEKERNEL_BACKEND=wezterm
source "${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

# ── Test 1: backend_available — wezterm exists ──
wezterm() { return 0; }
export -f wezterm
if backend_available; then
  echo "  PASS: backend_available returns 0 when wezterm exists"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: backend_available should return 0"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: backend_available — wezterm missing ──
unset -f wezterm 2>/dev/null || true
OLD_PATH="$PATH"
PATH=""
if backend_available; then
  echo "  FAIL: backend_available should return 1 when wezterm missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: backend_available returns 1 when wezterm missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi
PATH="$OLD_PATH"

# ── Test 3: backend_spawn_worker — spawns window and saves handle ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "wezterm $*" >> "$MOCK_LOG"
  if [[ "$1" == "cli" && "$2" == "spawn" ]]; then
    echo "42"  # mock pane ID
  fi
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    echo '[{"pane_id": 42, "workspace": "default"}]'
  fi
}
export -f wezterm

# Set WEZTERM_PANE for workspace resolution
export WEZTERM_PANE=42
ISSUE="300"
WORKTREE="/tmp/test-worktree"
backend_spawn_worker "$ISSUE" "worker" "$WORKTREE" "test prompt"

HANDLE_FILE="${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
assert_file_exists "Handle file created after spawn" "$HANDLE_FILE"

HANDLE=$(cat "$HANDLE_FILE")
assert_eq "Handle contains pane ID" "42" "$HANDLE"
rm -f "$MOCK_LOG"

# ── Test 4: backend_worker_alive — alive pane ──
wezterm() {
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    cat <<'MOCK_JSON'
[
  {"pane_id": 42, "window_id": 1, "workspace": "default"},
  {"pane_id": 43, "window_id": 1, "workspace": "default"}
]
MOCK_JSON
  fi
}
export -f wezterm
if backend_worker_alive "$ISSUE"; then
  echo "  PASS: backend_worker_alive returns 0 for existing pane"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: backend_worker_alive should return 0 for existing pane"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: backend_worker_alive — dead pane ──
wezterm() {
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    echo '[{"pane_id": 999, "window_id": 1}]'
  fi
}
export -f wezterm
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

# ── Test 7: backend_kill_worker — kills all panes in window ──
MOCK_LOG=$(mktemp)
wezterm() {
  echo "wezterm $*" >> "$MOCK_LOG"
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    cat <<'MOCK_JSON'
[
  {"pane_id": 42, "window_id": 1},
  {"pane_id": 43, "window_id": 1},
  {"pane_id": 44, "window_id": 1},
  {"pane_id": 99, "window_id": 2}
]
MOCK_JSON
  fi
}
export -f wezterm
backend_kill_worker "$ISSUE" 2>/dev/null

# All panes in window 1 should be killed
KILL_COUNT=$(grep -c "kill-pane" "$MOCK_LOG" || echo "0")
assert_eq "kill_worker kills 3 panes in same window" "3" "$KILL_COUNT"

# Pane 99 from window 2 should NOT be killed
if grep -q "pane-id 99" "$MOCK_LOG"; then
  echo "  FAIL: kill_worker should not kill panes in other windows"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: kill_worker only kills panes in same window"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi
rm -f "$MOCK_LOG"

# ── Test 8: backend_kill_worker — no error for missing handle ──
EXIT_CODE=0
backend_kill_worker "99999" 2>/dev/null || EXIT_CODE=$?
assert_eq "kill_worker for missing handle exits cleanly" "0" "$EXIT_CODE"

# ── Test 9: backend_worker_alive — compact JSON (no spaces) ──
echo "42" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
wezterm() {
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    echo '[{"pane_id":42},{"pane_id":43}]'
  fi
}
export -f wezterm
if backend_worker_alive "$ISSUE"; then
  echo "  PASS: backend_worker_alive handles compact JSON"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: backend_worker_alive should handle compact JSON"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: backend_spawn_worker — writes payload to file instead of inline ──
# Verify that base64 payload is written to a file to avoid wezterm send-text 1024-byte limit.
MOCK_LOG=$(mktemp)
wezterm() {
  echo "wezterm $*" >> "$MOCK_LOG"
  if [[ "$1" == "cli" && "$2" == "spawn" ]]; then
    echo "42"  # mock pane ID
  fi
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    echo '[{"pane_id": 42, "workspace": "default"}]'
  fi
}
export -f wezterm
export WEZTERM_PANE=42
ISSUE="301"
WORKTREE="/tmp/test-worktree"
backend_spawn_worker "$ISSUE" "worker" "$WORKTREE" "test prompt with long content"

PAYLOAD_FILE="${CEKERNEL_IPC_DIR}/payload-${ISSUE}.b64"
assert_file_exists "Payload file created after spawn" "$PAYLOAD_FILE"

# Verify payload file contains valid base64 that decodes to valid JSON
DECODED=$(base64 -d < "$PAYLOAD_FILE" 2>/dev/null || base64 -D < "$PAYLOAD_FILE" 2>/dev/null || echo "")
if echo "$DECODED" | jq -e . >/dev/null 2>&1; then
  echo "  PASS: Payload file contains valid base64-encoded JSON"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Payload file should contain valid base64-encoded JSON"
  echo "    decoded: ${DECODED}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify send-text commands are under 1024 bytes
while IFS= read -r line; do
  BYTE_LEN=${#line}
  if [[ "$BYTE_LEN" -gt 1024 ]]; then
    echo "  FAIL: send-text argument exceeds 1024 bytes (${BYTE_LEN} bytes)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
done < <(grep "send-text" "$MOCK_LOG")
echo "  PASS: All send-text commands are under 1024 bytes"
TESTS_PASSED=$((TESTS_PASSED + 1))
rm -f "$MOCK_LOG"

# ── Test 11: backend_kill_worker — cleans up payload file ──
# Payload file from test 10 should still exist
assert_file_exists "Payload file exists before kill" "$PAYLOAD_FILE"

# Create handle file for the kill
echo "42" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
MOCK_LOG=$(mktemp)
wezterm() {
  echo "wezterm $*" >> "$MOCK_LOG"
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    cat <<'MOCK_JSON'
[
  {"pane_id": 42, "window_id": 1}
]
MOCK_JSON
  fi
}
export -f wezterm
backend_kill_worker "$ISSUE" 2>/dev/null

assert_not_exists "Payload file cleaned up after kill" "$PAYLOAD_FILE"
rm -f "$MOCK_LOG"

# ── Cleanup ──
unset -f wezterm 2>/dev/null || true
unset WEZTERM_PANE 2>/dev/null || true
rm -rf "$CEKERNEL_IPC_DIR"

report_results
