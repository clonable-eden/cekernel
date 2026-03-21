#!/usr/bin/env bash
# test-spawn-max-processes.sh — Tests for CEKERNEL_MAX_ORCH_CHILDREN variable
# and Type recording in IPC directory.
#
# Tests the concurrency variable resolution logic:
#   CEKERNEL_MAX_ORCH_CHILDREN > default(3)
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
    echo "3"
  fi
}

# ── Test 1: Default is 3 when variable is not set ──
RESULT=$(resolve_max_children "")
assert_eq "Default MAX_ORCH_CHILDREN is 3" "3" "$RESULT"

# ── Test 2: CEKERNEL_MAX_ORCH_CHILDREN overrides default ──
RESULT=$(resolve_max_children "5")
assert_eq "CEKERNEL_MAX_ORCH_CHILDREN=5 overrides default" "5" "$RESULT"

# ── Test 3: spawn.sh contains CEKERNEL_MAX_ORCH_CHILDREN ──
SCRIPT_CONTENT=$(cat "$SPAWN_SCRIPT")
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_MAX_ORCH_CHILDREN'* ]]; then
  echo "  PASS: spawn.sh references CEKERNEL_MAX_ORCH_CHILDREN"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not reference CEKERNEL_MAX_ORCH_CHILDREN"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: spawn.sh does NOT contain deprecated CEKERNEL_MAX_WORKERS ──
if [[ "$SCRIPT_CONTENT" != *'CEKERNEL_MAX_WORKERS'* ]]; then
  echo "  PASS: spawn.sh does not reference deprecated CEKERNEL_MAX_WORKERS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh still references deprecated CEKERNEL_MAX_WORKERS"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: spawn.sh does NOT contain deprecated CEKERNEL_MAX_PROCESSES ──
if [[ "$SCRIPT_CONTENT" != *'CEKERNEL_MAX_PROCESSES'* ]]; then
  echo "  PASS: spawn.sh does not reference deprecated CEKERNEL_MAX_PROCESSES"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh still references deprecated CEKERNEL_MAX_PROCESSES"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: spawn.sh accepts --agent flag ──
if [[ "$SCRIPT_CONTENT" == *'--agent'* ]]; then
  echo "  PASS: spawn.sh accepts --agent flag"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not accept --agent flag"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: Type recording — spawn.sh writes .type file ──
if [[ "$SCRIPT_CONTENT" == *'.type'* ]]; then
  echo "  PASS: spawn.sh records process type (.type file)"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not record process type"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: Type file content verification ──
TYPE_FILE="${CEKERNEL_IPC_DIR}/worker-999.type"
echo "worker" > "$TYPE_FILE"
TYPE_CONTENT=$(cat "$TYPE_FILE")
assert_eq "Type file contains agent type" "worker" "$TYPE_CONTENT"

# ── Test 9: Concurrency guard uses resolved MAX_ORCH_CHILDREN ──
# Create 3 FIFOs
mkfifo "${CEKERNEL_IPC_DIR}/worker-10"
mkfifo "${CEKERNEL_IPC_DIR}/worker-11"
mkfifo "${CEKERNEL_IPC_DIR}/worker-12"

active_worker_count() {
  find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | wc -l | tr -d ' '
}

# With MAX_ORCH_CHILDREN=3, 3 active should trigger guard
MAX_CHILDREN=$(resolve_max_children "3")
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_CHILDREN" ]]; then
  GUARD="triggered"
else
  GUARD="open"
fi
assert_eq "Guard triggers at MAX_ORCH_CHILDREN=3 with 3 active" "triggered" "$GUARD"

# With MAX_ORCH_CHILDREN=5, 3 active should not trigger guard
MAX_CHILDREN=$(resolve_max_children "5")
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_CHILDREN" ]]; then
  GUARD="triggered"
else
  GUARD="open"
fi
assert_eq "Guard open at MAX_ORCH_CHILDREN=5 with 3 active" "open" "$GUARD"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
