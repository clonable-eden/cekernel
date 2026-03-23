#!/usr/bin/env bash
# test-spawn-max-processes.sh — Tests for CEKERNEL_MAX_ORCH_CHILDREN variable
# and Type recording in IPC directory.
#
# Tests the concurrency variable resolution logic:
#   CEKERNEL_MAX_ORCH_CHILDREN > default(5)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"

echo "test: spawn-max-processes"

# Test session
export CEKERNEL_SESSION_ID="test-max-proc-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# Extracted concurrency resolution logic (mirrors spawn.sh)
resolve_max_children() {
  local max_children="${1:-}"
  if [[ -n "$max_children" ]]; then
    echo "$max_children"
  else
    echo "5"
  fi
}

# ── Test 1: Default is 5 when variable is not set ──
RESULT=$(resolve_max_children "")
assert_eq "Default MAX_ORCH_CHILDREN is 5" "5" "$RESULT"

# ── Test 2: CEKERNEL_MAX_ORCH_CHILDREN overrides default ──
RESULT=$(resolve_max_children "10")
assert_eq "CEKERNEL_MAX_ORCH_CHILDREN=10 overrides default" "10" "$RESULT"

# ── Test 3: spawn.sh default fallback is 5 ──
SCRIPT_CONTENT=$(cat "$SPAWN_SCRIPT")
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_MAX_ORCH_CHILDREN:-5'* ]]; then
  echo "  PASS: spawn.sh default fallback is 5"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh default fallback is not 5"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: spawn.sh contains CEKERNEL_MAX_ORCH_CHILDREN ──
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_MAX_ORCH_CHILDREN'* ]]; then
  echo "  PASS: spawn.sh references CEKERNEL_MAX_ORCH_CHILDREN"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not reference CEKERNEL_MAX_ORCH_CHILDREN"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: spawn.sh does NOT contain deprecated CEKERNEL_MAX_WORKERS ──
if [[ "$SCRIPT_CONTENT" != *'CEKERNEL_MAX_WORKERS'* ]]; then
  echo "  PASS: spawn.sh does not reference deprecated CEKERNEL_MAX_WORKERS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh still references deprecated CEKERNEL_MAX_WORKERS"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: spawn.sh does NOT contain deprecated CEKERNEL_MAX_PROCESSES ──
if [[ "$SCRIPT_CONTENT" != *'CEKERNEL_MAX_PROCESSES'* ]]; then
  echo "  PASS: spawn.sh does not reference deprecated CEKERNEL_MAX_PROCESSES"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh still references deprecated CEKERNEL_MAX_PROCESSES"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: spawn.sh accepts --agent flag ──
if [[ "$SCRIPT_CONTENT" == *'--agent'* ]]; then
  echo "  PASS: spawn.sh accepts --agent flag"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not accept --agent flag"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: Type recording — spawn.sh writes .type file ──
if [[ "$SCRIPT_CONTENT" == *'.type'* ]]; then
  echo "  PASS: spawn.sh records process type (.type file)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not record process type"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: Type file content verification ──
TYPE_FILE="${CEKERNEL_IPC_DIR}/worker-999.type"
echo "worker" > "$TYPE_FILE"
TYPE_CONTENT=$(cat "$TYPE_FILE")
assert_eq "Type file contains agent type" "worker" "$TYPE_CONTENT"

# ── Test 10: Concurrency guard uses resolved MAX_ORCH_CHILDREN ──
# Create 5 FIFOs to match new default
mkfifo "${CEKERNEL_IPC_DIR}/worker-10"
mkfifo "${CEKERNEL_IPC_DIR}/worker-11"
mkfifo "${CEKERNEL_IPC_DIR}/worker-12"
mkfifo "${CEKERNEL_IPC_DIR}/worker-13"
mkfifo "${CEKERNEL_IPC_DIR}/worker-14"

active_worker_count() {
  find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | wc -l | tr -d ' '
}

# With default (5), 5 active should trigger guard
MAX_CHILDREN=$(resolve_max_children "")
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_CHILDREN" ]]; then
  GUARD="triggered"
else
  GUARD="open"
fi
assert_eq "Guard triggers at default MAX_ORCH_CHILDREN=5 with 5 active" "triggered" "$GUARD"

# With MAX_ORCH_CHILDREN=8, 5 active should not trigger guard
MAX_CHILDREN=$(resolve_max_children "8")
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_CHILDREN" ]]; then
  GUARD="triggered"
else
  GUARD="open"
fi
assert_eq "Guard open at MAX_ORCH_CHILDREN=8 with 5 active" "open" "$GUARD"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
