#!/usr/bin/env bash
# test-worker-status-state.sh — Tests for worker-status.sh state field integration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATUS_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/worker-status.sh"

echo "test: worker-status state integration"

export CEKERNEL_SESSION_ID="test-wstatus-state-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Test 1: Worker with state file shows state in output ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-30"
worker_state_write 30 RUNNING "phase1:implement"
OUTPUT=$(bash "$STATUS_SCRIPT")
assert_match "Output includes state field" '"state":"RUNNING"' "$OUTPUT"

# ── Test 2: Worker without state file shows UNKNOWN ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-31"
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":31')
assert_match "Missing state shows UNKNOWN" '"state":"UNKNOWN"' "$OUTPUT"

# ── Test 3: State detail is included in output ──
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":30')
assert_match "State detail included" '"state_detail":"phase1:implement"' "$OUTPUT"

# ── Test 4: TERMINATED worker with FIFO still shows state ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-32"
worker_state_write 32 TERMINATED "merged"
OUTPUT=$(bash "$STATUS_SCRIPT" | grep '"issue":32')
assert_match "TERMINATED state shown" '"state":"TERMINATED"' "$OUTPUT"

report_results
