#!/usr/bin/env bash
# test-worker-status.sh — Tests for worker-status.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATUS_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/worker-status.sh"

echo "test: worker-status"

# Test session
export CEKERNEL_SESSION_ID="test-wstatus-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Test 1: Empty output with no workers ──
OUTPUT=$(bash "$STATUS_SCRIPT")
assert_eq "No workers: empty output" "" "$OUTPUT"

# ── Test 2: One JSON line after creating FIFO ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-20"
OUTPUT=$(bash "$STATUS_SCRIPT")
LINE_COUNT=$(echo "$OUTPUT" | grep -c 'issue' || true)
assert_eq "One worker: one JSON line" "1" "$LINE_COUNT"

# ── Test 3: Issue number is correctly included ──
assert_match "Output contains issue 20" '"issue":20' "$OUTPUT"

# ── Test 4: FIFO path is included ──
assert_match "Output contains FIFO path" "worker-20" "$OUTPUT"

# ── Test 5: Multiple workers produce multiple lines ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-21"
mkfifo "${CEKERNEL_IPC_DIR}/worker-22"
OUTPUT=$(bash "$STATUS_SCRIPT")
LINE_COUNT=$(echo "$OUTPUT" | grep -c 'issue')
assert_eq "Three workers: three JSON lines" "3" "$LINE_COUNT"

# ── Test 6: Uptime field is included ──
assert_match "Output contains uptime field" '"uptime":' "$OUTPUT"

# ── Test 7: Exit 1 when session directory does not exist ──
rm -rf "$CEKERNEL_IPC_DIR"
export CEKERNEL_SESSION_ID="test-wstatus-nonexistent"
export CEKERNEL_IPC_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}/ipc/${CEKERNEL_SESSION_ID}"
EXIT_CODE=0
bash "$STATUS_SCRIPT" 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing session dir: exit 1" "1" "$EXIT_CODE"

# ── Cleanup ──
export CEKERNEL_SESSION_ID="test-wstatus-00000001"
export CEKERNEL_IPC_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}/ipc/${CEKERNEL_SESSION_ID}"
rm -rf "$CEKERNEL_IPC_DIR"

report_results
