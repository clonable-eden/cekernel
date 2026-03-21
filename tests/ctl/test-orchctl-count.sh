#!/usr/bin/env bash
# test-orchctl-count.sh — Tests for orchctl.sh count command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCHCTL="${CEKERNEL_DIR}/scripts/ctl/orchctl.sh"

echo "test: orchctl count"

# ── Isolated IPC base for test isolation ──
IPC_BASE=$(mktemp -d /tmp/cekernel-test-orchctl-count.XXXXXX)
export CEKERNEL_IPC_BASE="$IPC_BASE"

# ── Cleanup ──
BGPIDS=""
cleanup() {
  for p in $BGPIDS; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$IPC_BASE"
}
trap cleanup EXIT

# ══════════════════════════════════════════════
# count: 0 orchestrators
# ══════════════════════════════════════════════

# ── Test 1: count with no sessions → 0 ──
OUTPUT=$(bash "$ORCHCTL" count 2>/dev/null)
assert_eq "count no sessions" "0" "$OUTPUT"

# ── Test 2: count with session but no orchestrator.pid → 0 ──
SESSION_A="test-count-repo-00000001"
IPC_A="${IPC_BASE}/${SESSION_A}"
mkdir -p "$IPC_A"
OUTPUT=$(bash "$ORCHCTL" count 2>/dev/null)
assert_eq "count no pid file" "0" "$OUTPUT"

# ══════════════════════════════════════════════
# count: dead PID is not counted
# ══════════════════════════════════════════════

# ── Test 3: count with dead PID → 0 ──
echo "99999" > "${IPC_A}/orchestrator.pid"
OUTPUT=$(bash "$ORCHCTL" count 2>/dev/null)
assert_eq "count dead PID" "0" "$OUTPUT"

# ══════════════════════════════════════════════
# count: 1 live orchestrator
# ══════════════════════════════════════════════

# ── Test 4: count with 1 live PID → 1 ──
(sleep 300) &
PID1=$!
BGPIDS="$BGPIDS$PID1 "
echo "$PID1" > "${IPC_A}/orchestrator.pid"
OUTPUT=$(bash "$ORCHCTL" count 2>/dev/null)
assert_eq "count 1 live" "1" "$OUTPUT"

# ══════════════════════════════════════════════
# count: multiple live orchestrators
# ══════════════════════════════════════════════

# ── Test 5: count with 2 live PIDs across sessions → 2 ──
SESSION_B="test-count-repo-00000002"
IPC_B="${IPC_BASE}/${SESSION_B}"
mkdir -p "$IPC_B"
(sleep 300) &
PID2=$!
BGPIDS="$BGPIDS$PID2 "
echo "$PID2" > "${IPC_B}/orchestrator.pid"
OUTPUT=$(bash "$ORCHCTL" count 2>/dev/null)
assert_eq "count 2 live" "2" "$OUTPUT"

# ══════════════════════════════════════════════
# count: mix of live and dead
# ══════════════════════════════════════════════

# ── Test 6: 2 live + 1 dead → 2 ──
SESSION_C="test-count-repo-00000003"
IPC_C="${IPC_BASE}/${SESSION_C}"
mkdir -p "$IPC_C"
echo "99998" > "${IPC_C}/orchestrator.pid"
OUTPUT=$(bash "$ORCHCTL" count 2>/dev/null)
assert_eq "count 2 live + 1 dead" "2" "$OUTPUT"

# ══════════════════════════════════════════════
# count: output format (single integer, no label)
# ══════════════════════════════════════════════

# ── Test 7: output is a plain integer (no extra text) ──
assert_match "count output is integer" '^[0-9]+$' "$OUTPUT"

report_results
