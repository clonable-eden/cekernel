#!/usr/bin/env bash
# test-phase-transition.sh — Tests for phase-transition.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: phase-transition"

# Test session
export CEKERNEL_SESSION_ID="test-phase-transition-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup: Ensure clean state ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

PHASE_TRANSITION="${CEKERNEL_DIR}/scripts/process/phase-transition.sh"

# ── Test 1: No signal → writes state and exits 0 ──
EXIT_CODE=0
bash "$PHASE_TRANSITION" 100 RUNNING "phase1:implement" || EXIT_CODE=$?
assert_eq "No signal exits 0" "0" "$EXIT_CODE"

# Verify state was written
STATE_FILE="${CEKERNEL_IPC_DIR}/worker-100.state"
assert_file_exists "State file created" "$STATE_FILE"
STATE_CONTENT=$(cat "$STATE_FILE")
assert_match "State contains RUNNING" "^RUNNING:" "$STATE_CONTENT"
assert_match "State contains detail" "phase1:implement" "$STATE_CONTENT"

# ── Test 2: TERM signal → outputs signal and exits 3 ──
echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-101.signal"
EXIT_CODE=0
OUTPUT=$(bash "$PHASE_TRANSITION" 101 RUNNING "phase1:implement" 2>/dev/null) || EXIT_CODE=$?
assert_eq "TERM signal exits 3" "3" "$EXIT_CODE"
assert_eq "Output is TERM" "TERM" "$OUTPUT"
assert_not_exists "Signal file consumed" "${CEKERNEL_IPC_DIR}/worker-101.signal"

# Verify state was NOT written (signal takes precedence)
STATE_FILE_101="${CEKERNEL_IPC_DIR}/worker-101.state"
assert_not_exists "State file not created when signal found" "$STATE_FILE_101"

# ── Test 3: SUSPEND signal → outputs signal and exits 3 ──
echo "SUSPEND" > "${CEKERNEL_IPC_DIR}/worker-102.signal"
EXIT_CODE=0
OUTPUT=$(bash "$PHASE_TRANSITION" 102 WAITING "phase3:ci-waiting" 2>/dev/null) || EXIT_CODE=$?
assert_eq "SUSPEND signal exits 3" "3" "$EXIT_CODE"
assert_eq "Output is SUSPEND" "SUSPEND" "$OUTPUT"
assert_not_exists "SUSPEND signal file consumed" "${CEKERNEL_IPC_DIR}/worker-102.signal"

# ── Test 4: Missing issue number exits with error ──
EXIT_CODE=0
bash "$PHASE_TRANSITION" 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing issue number exits non-zero" "1" "$EXIT_CODE"

# ── Test 5: Missing state exits with error ──
EXIT_CODE=0
bash "$PHASE_TRANSITION" 200 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing state exits non-zero" "1" "$EXIT_CODE"

# ── Test 6: Detail is optional ──
EXIT_CODE=0
bash "$PHASE_TRANSITION" 103 RUNNING || EXIT_CODE=$?
assert_eq "No detail exits 0" "0" "$EXIT_CODE"
STATE_FILE_103="${CEKERNEL_IPC_DIR}/worker-103.state"
assert_file_exists "State file created without detail" "$STATE_FILE_103"

# ── Test 7: WAITING state works ──
EXIT_CODE=0
bash "$PHASE_TRANSITION" 104 WAITING "phase3:ci-waiting" || EXIT_CODE=$?
assert_eq "WAITING state exits 0" "0" "$EXIT_CODE"
STATE_FILE_104="${CEKERNEL_IPC_DIR}/worker-104.state"
STATE_CONTENT_104=$(cat "$STATE_FILE_104")
assert_match "State contains WAITING" "^WAITING:" "$STATE_CONTENT_104"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
