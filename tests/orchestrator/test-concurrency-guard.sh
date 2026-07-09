#!/usr/bin/env bash
# test-concurrency-guard.sh — Concurrency guard tests for spawn-worker.sh
#
# ADR-0020 Phase 1+3: concurrency is based on non-TERMINATED state files,
# not FIFO count. This test exercises the state-based counting logic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: concurrency-guard"

# Test session
export CEKERNEL_SESSION_ID="test-concurrency-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

# ── Setup: Ensure clean state ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# Extracted active_worker_count (mirrors spawn.sh ADR-0020 Phase 1)
active_worker_count() {
  local count=0
  for sf in "$CEKERNEL_IPC_DIR"/worker-*.state; do
    [[ -f "$sf" ]] || continue
    local line
    line=$(cat "$sf")
    local state="${line%%:*}"
    if [[ "$state" != "TERMINATED" ]]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# ── Test 1: Count is 0 with no workers ──
COUNT=$(active_worker_count)
assert_eq "No workers: count is 0" "0" "$COUNT"

# ── Test 2: Create 1 RUNNING state → count is 1 ──
worker_state_write 10 RUNNING "phase1:implement"
COUNT=$(active_worker_count)
assert_eq "One RUNNING worker: count is 1" "1" "$COUNT"

# ── Test 3: Add state files up to 3 → count is 3 ──
worker_state_write 11 RUNNING "phase1:implement"
worker_state_write 12 WAITING "phase3:ci-waiting"
COUNT=$(active_worker_count)
assert_eq "Three non-TERMINATED workers: count is 3" "3" "$COUNT"

# ── Test 4: Guard triggers at MAX_ORCH_CHILDREN=3 with 3 active ──
MAX_ORCH_CHILDREN=3
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_ORCH_CHILDREN" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard triggers at MAX_ORCH_CHILDREN=3 with 3 active" "yes" "$GUARD_TRIGGERED"

# ── Test 5: TERMINATED state → not counted → guard released ──
worker_state_write 12 TERMINATED "merged:99"
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_ORCH_CHILDREN" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard released after TERMINATED state" "no" "$GUARD_TRIGGERED"

# ── Test 6: MAX_ORCH_CHILDREN=5 with 2 active → guard not triggered ──
MAX_ORCH_CHILDREN=5
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_ORCH_CHILDREN" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard not triggered: 2 active < MAX_ORCH_CHILDREN=5" "no" "$GUARD_TRIGGERED"

# ── Test 7: SUSPENDED state is counted as active ──
worker_state_write 13 SUSPENDED "checkpoint-saved"
COUNT=$(active_worker_count)
assert_eq "SUSPENDED counts as active" "3" "$COUNT"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
