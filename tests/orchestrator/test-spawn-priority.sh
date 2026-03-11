#!/usr/bin/env bash
# test-spawn-priority.sh — Tests for spawn-worker.sh --priority flag parsing
#
# spawn-worker.sh cannot be run directly due to terminal/git dependencies.
# Here we extract and test the priority flag parsing and file writing logic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-priority"

export CEKERNEL_SESSION_ID="test-spawn-prio-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/worker-priority.sh"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# ── Simulate spawn.sh flag parsing logic ──
# Extract the flag parsing pattern from spawn.sh
parse_spawn_flags() {
  local PRIORITY="normal"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) PRIORITY="${2:?--priority requires a value}"; shift 2 ;;
      *) break ;;
    esac
  done
  echo "$PRIORITY"
}

# ── Test 1: Default priority is "normal" when no flag ──
RESULT=$(parse_spawn_flags)
assert_eq "Default priority is normal" "normal" "$RESULT"

# ── Test 2: --priority high is parsed ──
RESULT=$(parse_spawn_flags --priority high)
assert_eq "--priority high parsed" "high" "$RESULT"

# ── Test 3: --priority low is parsed ──
RESULT=$(parse_spawn_flags --priority low)
assert_eq "--priority low parsed" "low" "$RESULT"

# ── Test 4: --priority critical is parsed ──
RESULT=$(parse_spawn_flags --priority critical)
assert_eq "--priority critical parsed" "critical" "$RESULT"

# ── Test 5: --priority with numeric value is parsed ──
RESULT=$(parse_spawn_flags --priority 3)
assert_eq "--priority 3 parsed" "3" "$RESULT"

# ── Test 6: Flags before positional args are parsed correctly ──
RESULT=$(parse_spawn_flags --priority high 42 main)
assert_eq "Flag before positional args" "high" "$RESULT"

# ── Test 7: Priority file is written correctly after spawn ──
worker_priority_write 80 high
RESULT=$(worker_priority_read 80)
assert_match "Priority file written with high" '"priority":5' "$RESULT"

# ── Test 8: Default priority writes normal (10) ──
worker_priority_write 81 normal
RESULT=$(worker_priority_read 81)
assert_match "Default priority is normal/10" '"priority":10' "$RESULT"

report_results
