#!/usr/bin/env bash
# test-worker-priority.sh — Tests for shared/worker-priority.sh priority management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: worker-priority"

export CEKERNEL_SESSION_ID="test-wpriority-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# Source the module under test
source "${CEKERNEL_DIR}/scripts/shared/worker-priority.sh"

# ── Test 1: Write numeric priority creates priority file ──
worker_priority_write 60 10
assert_file_exists "Numeric priority creates file" "${CEKERNEL_IPC_DIR}/worker-60.priority"

# ── Test 2: Priority file contains numeric value ──
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-60.priority")
assert_eq "Priority file contains 10" "10" "$CONTENT"

# ── Test 3: Read priority returns correct JSON ──
RESULT=$(worker_priority_read 60)
assert_match "Read returns priority field" '"priority":10' "$RESULT"
assert_match "Read returns issue field" '"issue":60' "$RESULT"
assert_match "Read returns priority_name" '"priority_name":"normal"' "$RESULT"

# ── Test 4: Write named priority "critical" resolves to 0 ──
worker_priority_write 61 critical
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-61.priority")
assert_eq "critical resolves to 0" "0" "$CONTENT"

# ── Test 5: Write named priority "high" resolves to 5 ──
worker_priority_write 62 high
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-62.priority")
assert_eq "high resolves to 5" "5" "$CONTENT"

# ── Test 6: Write named priority "normal" resolves to 10 ──
worker_priority_write 63 normal
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-63.priority")
assert_eq "normal resolves to 10" "10" "$CONTENT"

# ── Test 7: Write named priority "low" resolves to 15 ──
worker_priority_write 64 low
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-64.priority")
assert_eq "low resolves to 15" "15" "$CONTENT"

# ── Test 8: Read nonexistent priority returns default (normal/10) ──
RESULT=$(worker_priority_read 999)
assert_match "Missing priority returns default 10" '"priority":10' "$RESULT"
assert_match "Missing priority returns normal name" '"priority_name":"normal"' "$RESULT"

# ── Test 9: Invalid priority name is rejected ──
EXIT_CODE=0
worker_priority_write 65 invalid 2>/dev/null || EXIT_CODE=$?
assert_eq "Invalid priority name rejected with exit 1" "1" "$EXIT_CODE"

# ── Test 10: Out of range numeric priority is rejected ──
EXIT_CODE=0
worker_priority_write 66 20 2>/dev/null || EXIT_CODE=$?
assert_eq "Priority 20 (out of range) rejected" "1" "$EXIT_CODE"

# ── Test 11: Negative numeric priority is rejected ──
EXIT_CODE=0
worker_priority_write 67 -1 2>/dev/null || EXIT_CODE=$?
assert_eq "Negative priority rejected" "1" "$EXIT_CODE"

# ── Test 12: Priority name resolution for boundary values ──
worker_priority_write 68 0
RESULT=$(worker_priority_read 68)
assert_match "Priority 0 maps to critical" '"priority_name":"critical"' "$RESULT"

worker_priority_write 69 19
RESULT=$(worker_priority_read 69)
assert_match "Priority 19 maps to low" '"priority_name":"low"' "$RESULT"

# ── Test 13: Priority 7 (between critical and normal) maps to high ──
worker_priority_write 70 7
RESULT=$(worker_priority_read 70)
assert_match "Priority 7 maps to high" '"priority_name":"high"' "$RESULT"

# ── Test 14: Priority 12 (between normal and low) maps to normal ──
worker_priority_write 71 12
RESULT=$(worker_priority_read 71)
assert_match "Priority 12 maps to normal" '"priority_name":"normal"' "$RESULT"

# ── Test 15: Overwrite existing priority ──
worker_priority_write 60 high
RESULT=$(worker_priority_read 60)
assert_match "Overwritten priority is high" '"priority":5' "$RESULT"

report_results
