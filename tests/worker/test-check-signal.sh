#!/usr/bin/env bash
# test-check-signal.sh — Tests for check-signal.sh (Worker-side signal detection)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: check-signal"

# Test session
export CEKERNEL_SESSION_ID="test-check-signal-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup: Ensure clean state ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

CHECK_SIGNAL="${CEKERNEL_DIR}/scripts/worker/check-signal.sh"

# ── Test 1: No signal file → exit 1 (no signal) ──
EXIT_CODE=0
bash "$CHECK_SIGNAL" 42 >/dev/null 2>&1 || EXIT_CODE=$?
assert_eq "No signal file exits 1" "1" "$EXIT_CODE"

# ── Test 2: TERM signal file exists → exit 0, outputs signal name, consumes file ──
echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-42.signal"
OUTPUT=$(bash "$CHECK_SIGNAL" 42)
EXIT_CODE=$?
assert_eq "TERM signal detected exits 0" "0" "$EXIT_CODE"
assert_eq "Output is TERM" "TERM" "$OUTPUT"
assert_not_exists "Signal file consumed after check" "${CEKERNEL_IPC_DIR}/worker-42.signal"

# ── Test 3: SUSPEND signal file exists → exit 0, outputs SUSPEND, consumes file ──
echo "SUSPEND" > "${CEKERNEL_IPC_DIR}/worker-43.signal"
OUTPUT=$(bash "$CHECK_SIGNAL" 43)
EXIT_CODE=$?
assert_eq "SUSPEND signal detected exits 0" "0" "$EXIT_CODE"
assert_eq "Output is SUSPEND" "SUSPEND" "$OUTPUT"
assert_not_exists "SUSPEND signal file consumed after check" "${CEKERNEL_IPC_DIR}/worker-43.signal"

# ── Test 4: Missing issue number exits with error ──
EXIT_CODE=0
bash "$CHECK_SIGNAL" 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing issue number exits non-zero" "1" "$EXIT_CODE"

# ── Test 5: Signal file with trailing whitespace is trimmed ──
printf "TERM\n" > "${CEKERNEL_IPC_DIR}/worker-55.signal"
OUTPUT=$(bash "$CHECK_SIGNAL" 55)
assert_eq "Trailing newline trimmed" "TERM" "$OUTPUT"
assert_not_exists "Signal file consumed" "${CEKERNEL_IPC_DIR}/worker-55.signal"

# ── Test 6: Log entry is recorded when signal is consumed ──
mkdir -p "${CEKERNEL_IPC_DIR}/logs"
LOG_FILE="${CEKERNEL_IPC_DIR}/logs/worker-60.log"
echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-60.signal"
bash "$CHECK_SIGNAL" 60 >/dev/null
assert_file_exists "Log file created" "$LOG_FILE"
LOG_CONTENT=$(cat "$LOG_FILE")
assert_match "Log contains SIGNAL_RECEIVED" "SIGNAL_RECEIVED" "$LOG_CONTENT"
assert_match "Log contains issue number" "issue=#60" "$LOG_CONTENT"
assert_match "Log contains signal name" "signal=TERM" "$LOG_CONTENT"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
