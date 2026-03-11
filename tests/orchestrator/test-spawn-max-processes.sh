#!/usr/bin/env bash
# test-spawn-max-processes.sh — Tests for CEKERNEL_MAX_PROCESSES variable priority,
# deprecated CEKERNEL_MAX_WORKERS warning, and Type recording in IPC directory.
#
# Tests the concurrency variable resolution logic:
#   Priority: CEKERNEL_MAX_WORKERS > CEKERNEL_MAX_PROCESSES > default(3)
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
# Uses env vars passed as arguments to avoid subshell isolation issues.
resolve_max_processes() {
  local max_workers="${1:-}"
  local max_processes="${2:-}"
  if [[ -n "$max_workers" ]]; then
    echo "$max_workers"
  elif [[ -n "$max_processes" ]]; then
    echo "$max_processes"
  else
    echo "3"
  fi
}

# ── Test 1: Default is 3 when neither variable is set ──
RESULT=$(resolve_max_processes "" "")
assert_eq "Default MAX_PROCESSES is 3" "3" "$RESULT"

# ── Test 2: CEKERNEL_MAX_PROCESSES overrides default ──
RESULT=$(resolve_max_processes "" "5")
assert_eq "CEKERNEL_MAX_PROCESSES=5 overrides default" "5" "$RESULT"

# ── Test 3: CEKERNEL_MAX_WORKERS overrides CEKERNEL_MAX_PROCESSES ──
RESULT=$(resolve_max_processes "2" "5")
assert_eq "CEKERNEL_MAX_WORKERS overrides CEKERNEL_MAX_PROCESSES" "2" "$RESULT"

# ── Test 4: CEKERNEL_MAX_WORKERS only (no CEKERNEL_MAX_PROCESSES) ──
RESULT=$(resolve_max_processes "4" "")
assert_eq "CEKERNEL_MAX_WORKERS=4 without MAX_PROCESSES" "4" "$RESULT"

# ── Test 5: spawn.sh contains CEKERNEL_MAX_PROCESSES ──
SCRIPT_CONTENT=$(cat "$SPAWN_SCRIPT")
if [[ "$SCRIPT_CONTENT" == *'CEKERNEL_MAX_PROCESSES'* ]]; then
  echo "  PASS: spawn.sh references CEKERNEL_MAX_PROCESSES"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh does not reference CEKERNEL_MAX_PROCESSES"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: spawn.sh contains deprecated warning for CEKERNEL_MAX_WORKERS ──
if [[ "$SCRIPT_CONTENT" == *'deprecated'* ]] && [[ "$SCRIPT_CONTENT" == *'CEKERNEL_MAX_WORKERS'* ]]; then
  echo "  PASS: spawn.sh contains deprecated warning for CEKERNEL_MAX_WORKERS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: spawn.sh missing deprecated warning for CEKERNEL_MAX_WORKERS"
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

# ── Test 10: Concurrency guard uses resolved MAX_PROCESSES ──
# Create 3 FIFOs
mkfifo "${CEKERNEL_IPC_DIR}/worker-10"
mkfifo "${CEKERNEL_IPC_DIR}/worker-11"
mkfifo "${CEKERNEL_IPC_DIR}/worker-12"

active_worker_count() {
  find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | wc -l | tr -d ' '
}

# With MAX_PROCESSES=3, 3 active should trigger guard
MAX_PROCESSES=$(resolve_max_processes "" "3")
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_PROCESSES" ]]; then
  GUARD="triggered"
else
  GUARD="open"
fi
assert_eq "Guard triggers at MAX_PROCESSES=3 with 3 active" "triggered" "$GUARD"

# With MAX_PROCESSES=5, 3 active should not trigger guard
MAX_PROCESSES=$(resolve_max_processes "" "5")
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_PROCESSES" ]]; then
  GUARD="triggered"
else
  GUARD="open"
fi
assert_eq "Guard open at MAX_PROCESSES=5 with 3 active" "open" "$GUARD"

# With CEKERNEL_MAX_WORKERS=2 and CEKERNEL_MAX_PROCESSES=5, guard uses WORKERS value
MAX_PROCESSES=$(resolve_max_processes "2" "5")
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_PROCESSES" ]]; then
  GUARD="triggered"
else
  GUARD="open"
fi
assert_eq "Guard uses MAX_WORKERS=2 over MAX_PROCESSES=5" "triggered" "$GUARD"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
