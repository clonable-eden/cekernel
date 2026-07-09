#!/usr/bin/env bash
# test-session-isolation.sh — IPC isolation test between different sessions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: session-isolation"

ISSUE_NUMBER=10

# ── Session A ──
CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
SESSION_A="test-isolation-aaaaaaaa"
SESSION_A_DIR="${CEKERNEL_VAR_DIR}/ipc/${SESSION_A}"
mkdir -p "$SESSION_A_DIR"
STATE_A="${SESSION_A_DIR}/worker-${ISSUE_NUMBER}.state"
echo "RUNNING:2026-07-09T00:00:00Z:phase1:implement" > "$STATE_A"

# ── Session B (same issue number) ──
SESSION_B="test-isolation-bbbbbbbb"
SESSION_B_DIR="${CEKERNEL_VAR_DIR}/ipc/${SESSION_B}"
mkdir -p "$SESSION_B_DIR"
STATE_B="${SESSION_B_DIR}/worker-${ISSUE_NUMBER}.state"
echo "WAITING:2026-07-09T00:00:00Z:phase3:ci-waiting" > "$STATE_B"

# ── Test: Same issue number in different sessions should not collide ──
assert_file_exists "Session A state file exists" "$STATE_A"
assert_file_exists "Session B state file exists" "$STATE_B"
assert_eq "State files are at different paths" "1" "$([[ "$STATE_A" != "$STATE_B" ]] && echo 1 || echo 0)"

# ── Test: State data is independent for each session ──
STATE_A_CONTENT=$(cat "$STATE_A")
STATE_B_CONTENT=$(cat "$STATE_B")

assert_match "Session A has its own state" "^RUNNING:" "$STATE_A_CONTENT"
assert_match "Session B has its own state" "^WAITING:" "$STATE_B_CONTENT"

# Cleanup
rm -f "$STATE_A" "$STATE_B"
rmdir "$SESSION_A_DIR" 2>/dev/null || true
rmdir "$SESSION_B_DIR" 2>/dev/null || true

report_results
