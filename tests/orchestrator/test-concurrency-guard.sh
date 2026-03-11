#!/usr/bin/env bash
# test-concurrency-guard.sh — Concurrency guard tests for spawn-worker.sh
#
# spawn-worker.sh cannot be run directly due to WezTerm dependency.
# Here we extract and test the concurrency guard logic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: concurrency-guard"

# Test session
export CEKERNEL_SESSION_ID="test-concurrency-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup: Ensure clean state ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# Redefine active_worker_count (extracted from spawn-worker.sh)
active_worker_count() {
  find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | wc -l | tr -d ' '
}

# ── Test 1: Count is 0 with no workers ──
COUNT=$(active_worker_count)
assert_eq "No workers: count is 0" "0" "$COUNT"

# ── Test 2: Create 1 FIFO → count is 1 ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-10"
COUNT=$(active_worker_count)
assert_eq "One worker FIFO: count is 1" "1" "$COUNT"

# ── Test 3: Add FIFOs up to 3 → count is 3 ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-11"
mkfifo "${CEKERNEL_IPC_DIR}/worker-12"
COUNT=$(active_worker_count)
assert_eq "Three worker FIFOs: count is 3" "3" "$COUNT"

# ── Test 4: Guard triggers at MAX_PROCESSES=3 with 3 active ──
# Inline verification of spawn.sh guard logic
MAX_PROCESSES=3
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_PROCESSES" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard triggers at MAX_PROCESSES=3 with 3 active" "yes" "$GUARD_TRIGGERED"

# ── Test 5: Remove 1 FIFO → guard released ──
rm -f "${CEKERNEL_IPC_DIR}/worker-12"
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_PROCESSES" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard released after removing one FIFO" "no" "$GUARD_TRIGGERED"

# ── Test 6: MAX_PROCESSES=5 with 2 active → guard not triggered ──
MAX_PROCESSES=5
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_PROCESSES" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard not triggered: 2 active < MAX_PROCESSES=5" "no" "$GUARD_TRIGGERED"

# ── Test 7: Regular file (non-FIFO) is not counted ──
touch "${CEKERNEL_IPC_DIR}/worker-99"
COUNT=$(active_worker_count)
assert_eq "Regular file not counted as worker" "2" "$COUNT"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
