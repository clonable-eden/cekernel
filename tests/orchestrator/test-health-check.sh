#!/usr/bin/env bash
# test-health-check.sh — Zombie Worker detection tests
# ADR-0020 Phase 2: zombie = non-TERMINATED state + dead backend verdict.
# Workers are discovered by state file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: health-check"

export CEKERNEL_SESSION_ID="test-health-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-state.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$CEKERNEL_IPC_DIR"

# Use headless backend for tests (always available, even on CI without terminal)
export CEKERNEL_BACKEND=headless

# ── Test 1: TERMINATED state → skipped (not inspected) ──
worker_state_write 70 TERMINATED "ci-passed:55"
EXIT_CODE=0
bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 70 2>/dev/null || EXIT_CODE=$?
assert_eq "TERMINATED worker not inspected returns exit 0" "0" "$EXIT_CODE"

# ── Test 2: Non-TERMINATED state, no handle, no worktree → zombie ──
worker_state_write 71 RUNNING "phase1:implement"
RESULT=$(bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 71 2>/dev/null || true)
assert_match "Non-TERMINATED + dead reports zombie" '"status":"zombie"' "$RESULT"

# ── Test 3: No arguments → inspect all non-TERMINATED workers ──
worker_state_write 72 WAITING "phase3:ci-waiting"
RESULT=$(bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 2>/dev/null || true)
assert_match "Issue 71 found in scan" '"issue":71' "$RESULT"
assert_match "Issue 72 found in scan" '"issue":72' "$RESULT"

# ── Test 4: No non-TERMINATED state files → exit 0 ──
rm -f "${CEKERNEL_IPC_DIR}/worker-71.state" "${CEKERNEL_IPC_DIR}/worker-72.state"
EXIT_CODE=0
bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 2>/dev/null || EXIT_CODE=$?
assert_eq "No active workers returns exit 0" "0" "$EXIT_CODE"

report_results
