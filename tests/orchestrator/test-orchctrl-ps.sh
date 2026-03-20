#!/usr/bin/env bash
# test-orchctrl-ps.sh — Tests for orchctrl.sh ps command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCHCTRL="${CEKERNEL_DIR}/scripts/orchestrator/orchctrl.sh"

echo "test: orchctrl ps"

# ── Isolated IPC base for test isolation ──
IPC_BASE=$(mktemp -d /tmp/cekernel-test-orchctrl-ps.XXXXXX)
export CEKERNEL_IPC_BASE="$IPC_BASE"

SESSION="test-ps-repo-00000001"
IPC_DIR="${IPC_BASE}/${SESSION}"
mkdir -p "$IPC_DIR"

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
# ps: no orchestrator.pid → error
# ══════════════════════════════════════════════

# ── Test 1: ps with no sessions → "no orchestrators." ──
rm -rf "${IPC_BASE:?}/"*
OUTPUT=$(bash "$ORCHCTRL" ps 2>/dev/null)
assert_eq "ps no sessions" "no orchestrators." "$OUTPUT"

# ── Test 2: ps with session but no orchestrator.pid → skip ──
mkdir -p "$IPC_DIR"
OUTPUT=$(bash "$ORCHCTRL" ps 2>/dev/null)
assert_eq "ps no pid file" "no orchestrators." "$OUTPUT"

# ══════════════════════════════════════════════
# ps: orchestrator.pid with dead PID → shows not running
# ══════════════════════════════════════════════

# ── Test 3: ps with dead PID → shows not-running status ──
echo "99999" > "${IPC_DIR}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR}/orchestrator.spawned"
OUTPUT=$(bash "$ORCHCTRL" ps 2>/dev/null)
assert_match "ps dead PID shows not-running" "not-running" "$OUTPUT"

# ══════════════════════════════════════════════
# ps: orchestrator.pid with live PID → shows process tree
# ══════════════════════════════════════════════

# ── Test 4: ps with live PID → shows running orchestrator ──
# Start a background process that spawns children
(sleep 300) &
ORCH_PID=$!
BGPIDS="$BGPIDS$ORCH_PID "

echo "$ORCH_PID" > "${IPC_DIR}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR}/orchestrator.spawned"

OUTPUT=$(bash "$ORCHCTRL" ps 2>/dev/null)
assert_match "ps live PID shows session" "$SESSION" "$OUTPUT"
assert_match "ps live PID shows PID" "PID=${ORCH_PID}" "$OUTPUT"

# ── Test 5: ps shows running status ──
assert_match "ps live PID shows running" "running" "$OUTPUT"

# ══════════════════════════════════════════════
# ps: multiple sessions
# ══════════════════════════════════════════════

# ── Test 6: ps lists multiple sessions ──
SESSION_B="test-ps-repo2-00000002"
IPC_DIR_B="${IPC_BASE}/${SESSION_B}"
mkdir -p "$IPC_DIR_B"

(sleep 300) &
ORCH_PID_B=$!
BGPIDS="$BGPIDS$ORCH_PID_B "

echo "$ORCH_PID_B" > "${IPC_DIR_B}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR_B}/orchestrator.spawned"

OUTPUT=$(bash "$ORCHCTRL" ps 2>/dev/null)
LINE_COUNT=$(echo "$OUTPUT" | grep -c "orchestrator" || true)
assert_eq "ps multiple sessions: two orchestrators" "2" "$LINE_COUNT"

# ══════════════════════════════════════════════
# ps: child process listing
# ══════════════════════════════════════════════

# ── Test 7: ps with child processes ──
# Clean up and create a fresh process with actual children
kill "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true
kill "$ORCH_PID_B" 2>/dev/null || true
wait "$ORCH_PID_B" 2>/dev/null || true
rm -rf "${IPC_BASE:?}/"*

SESSION_C="test-ps-repo3-00000003"
IPC_DIR_C="${IPC_BASE}/${SESSION_C}"
mkdir -p "$IPC_DIR_C"

# Launch a parent with children
bash -c 'sleep 300 & sleep 300 & wait' &
PARENT_PID=$!
BGPIDS="$BGPIDS$PARENT_PID "
sleep 0.3  # Give children time to spawn

echo "$PARENT_PID" > "${IPC_DIR_C}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR_C}/orchestrator.spawned"

OUTPUT=$(bash "$ORCHCTRL" ps 2>/dev/null)
# Should show the parent orchestrator line
assert_match "ps parent shows orchestrator" "orchestrator" "$OUTPUT"
# Should show child processes (tree lines with └── or ├──)
CHILD_LINES=$(echo "$OUTPUT" | grep -cE '├──|└──' || true)
assert_match "ps shows child processes" "^[0-9]+$" "$CHILD_LINES"

# ══════════════════════════════════════════════
# ps: --session filter
# ══════════════════════════════════════════════

# ── Test 8: ps --session filters to specific session ──
# Add another session
SESSION_D="test-ps-repo4-00000004"
IPC_DIR_D="${IPC_BASE}/${SESSION_D}"
mkdir -p "$IPC_DIR_D"

(sleep 300) &
ORCH_PID_D=$!
BGPIDS="$BGPIDS$ORCH_PID_D "

echo "$ORCH_PID_D" > "${IPC_DIR_D}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR_D}/orchestrator.spawned"

OUTPUT=$(bash "$ORCHCTRL" ps --session "$SESSION_D" 2>/dev/null)
assert_match "ps --session filters correctly" "$SESSION_D" "$OUTPUT"
# Should NOT contain the other session
if echo "$OUTPUT" | grep -q "$SESSION_C"; then
  echo "  FAIL: ps --session should not show other sessions"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: ps --session excludes other sessions"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 9: ps --session with non-existent session → no orchestrators ──
OUTPUT=$(bash "$ORCHCTRL" ps --session "nonexistent-session" 2>/dev/null)
assert_eq "ps --session nonexistent" "no orchestrators." "$OUTPUT"

report_results
