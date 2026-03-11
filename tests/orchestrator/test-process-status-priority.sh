#!/usr/bin/env bash
# test-process-status-priority.sh — Tests for process-status.sh priority field integration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATUS_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/process-status.sh"

echo "test: process-status priority integration"

export CEKERNEL_SESSION_ID="test-pstatus-prio-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-priority.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Test 1: Worker with priority file shows priority in output ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-40"
worker_priority_write 40 high
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":40')
assert_match "Output includes priority field" '"priority":5' "$OUTPUT"
assert_match "Output includes priority_name field" '"priority_name":"high"' "$OUTPUT"

# ── Test 2: Worker without priority file shows default (normal/10) ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-41"
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":41')
assert_match "Missing priority shows default 10" '"priority":10' "$OUTPUT"
assert_match "Missing priority shows normal name" '"priority_name":"normal"' "$OUTPUT"

# ── Test 3: Critical priority shown correctly ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-42"
worker_priority_write 42 critical
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":42')
assert_match "Critical priority shown" '"priority":0' "$OUTPUT"
assert_match "Critical priority name shown" '"priority_name":"critical"' "$OUTPUT"

# ── Test 4: Low priority shown correctly ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-43"
worker_priority_write 43 low
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":43')
assert_match "Low priority shown" '"priority":15' "$OUTPUT"

report_results
