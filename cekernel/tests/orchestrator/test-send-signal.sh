#!/usr/bin/env bash
# test-send-signal.sh — Tests for send-signal.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: send-signal"

# Test session
export CEKERNEL_SESSION_ID="test-send-signal-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup: Ensure clean state ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

SEND_SIGNAL="${CEKERNEL_DIR}/scripts/orchestrator/send-signal.sh"

# ── Test 1: TERM signal creates signal file ──
bash "$SEND_SIGNAL" 42 TERM
SIGNAL_FILE="${CEKERNEL_IPC_DIR}/worker-42.signal"
assert_file_exists "TERM signal creates signal file" "$SIGNAL_FILE"
CONTENT=$(cat "$SIGNAL_FILE")
assert_eq "Signal file contains TERM" "TERM" "$CONTENT"
rm -f "$SIGNAL_FILE"

# ── Test 2: Missing issue number exits with error ──
OUTPUT=$(bash "$SEND_SIGNAL" 2>&1 || true)
EXIT_CODE=0
bash "$SEND_SIGNAL" 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing issue number exits non-zero" "1" "$EXIT_CODE"

# ── Test 3: Missing signal name exits with error ──
EXIT_CODE=0
bash "$SEND_SIGNAL" 42 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing signal name exits non-zero" "1" "$EXIT_CODE"

# ── Test 4: Unsupported signal is rejected ──
EXIT_CODE=0
bash "$SEND_SIGNAL" 42 HUP 2>/dev/null || EXIT_CODE=$?
assert_eq "Unsupported signal HUP is rejected" "1" "$EXIT_CODE"
assert_not_exists "No signal file for rejected signal" "${CEKERNEL_IPC_DIR}/worker-42.signal"

# ── Test 5: Signal file overwrites existing signal ──
echo "OLD" > "${CEKERNEL_IPC_DIR}/worker-50.signal"
bash "$SEND_SIGNAL" 50 TERM
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-50.signal")
assert_eq "Signal file overwritten with new signal" "TERM" "$CONTENT"
rm -f "${CEKERNEL_IPC_DIR}/worker-50.signal"

# ── Test 6: IPC directory does not exist → error ──
rm -rf "$CEKERNEL_IPC_DIR"
EXIT_CODE=0
bash "$SEND_SIGNAL" 42 TERM 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing IPC dir exits non-zero" "1" "$EXIT_CODE"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
