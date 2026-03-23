#!/usr/bin/env bash
# test-process-status.sh — Tests for process-status.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATUS_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/process-status.sh"

echo "test: process-status"

# Test session
export CEKERNEL_SESSION_ID="test-pstatus-00000001"
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
export CEKERNEL_SESSION_ID="test-pstatus-nonexistent"
export CEKERNEL_IPC_DIR="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}/ipc/${CEKERNEL_SESSION_ID}"
EXIT_CODE=0
bash "$STATUS_SCRIPT" 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing session dir: exit 1" "1" "$EXIT_CODE"

# ── Test 8: Type field from .type file ──
export CEKERNEL_SESSION_ID="test-pstatus-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-50"
echo "worker" > "${CEKERNEL_IPC_DIR}/worker-50.type"
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":50')
assert_match "Type field shows worker" '"type":"worker"' "$OUTPUT"

# ── Test 9: Type field shows reviewer ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-51"
echo "reviewer" > "${CEKERNEL_IPC_DIR}/worker-51.type"
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":51')
assert_match "Type field shows reviewer" '"type":"reviewer"' "$OUTPUT"

# ── Test 10: Missing type file defaults to unknown ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-52"
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":52')
assert_match "Missing type file shows unknown" '"type":"unknown"' "$OUTPUT"

# ── Test 11: Uptime reads from .spawned file (not FIFO stat) ──
export CEKERNEL_SESSION_ID="test-pstatus-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-60"
echo "worker" > "${CEKERNEL_IPC_DIR}/worker-60.type"
# Write epoch 0 to .spawned — forces a very large uptime (many hours)
echo "0" > "${CEKERNEL_IPC_DIR}/worker-60.spawned"
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":60')
# New code reads .spawned (epoch 0) → uptime in hours
# Old code reads FIFO mtime (just created) → uptime in seconds "Xs"
assert_match "Uptime reads from .spawned file (epoch 0 → hours)" '"uptime":"[0-9]+h' "$OUTPUT"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
