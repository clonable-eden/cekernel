#!/usr/bin/env bash
# test-orchctl-ps.sh — Tests for orchctl.sh ps command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCHCTL="${CEKERNEL_DIR}/scripts/ctl/orchctl.sh"

echo "test: orchctl ps"

# ── Isolated IPC base for test isolation ──
IPC_BASE=$(mktemp -d /tmp/cekernel-test-orchctl-ps.XXXXXX)
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
OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
assert_eq "ps no sessions" "no orchestrators." "$OUTPUT"

# ── Test 2: ps with session but no orchestrator.pid → skip ──
mkdir -p "$IPC_DIR"
OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
assert_eq "ps no pid file" "no orchestrators." "$OUTPUT"

# ══════════════════════════════════════════════
# ps: orchestrator.pid with dead PID → shows not running
# ══════════════════════════════════════════════

# ── Test 3: ps with dead PID → shows not-running status ──
echo "99999" > "${IPC_DIR}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR}/orchestrator.spawned"
OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
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

OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
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

OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
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

OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
# Should show the parent orchestrator line
assert_match "ps parent shows orchestrator" "orchestrator" "$OUTPUT"
# Should show child processes (tree lines with └── or ├──)
CHILD_LINES=$(echo "$OUTPUT" | grep -cE '├──|└──' || true)
assert_match "ps shows child processes" "^[1-9][0-9]*$" "$CHILD_LINES"

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

OUTPUT=$(bash "$ORCHCTL" ps --session "$SESSION_D" 2>/dev/null)
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
OUTPUT=$(bash "$ORCHCTL" ps --session "nonexistent-session" 2>/dev/null)
assert_eq "ps --session nonexistent" "no orchestrators." "$OUTPUT"

# ══════════════════════════════════════════════
# ps: managed processes from handle files
# ══════════════════════════════════════════════

# Clean up previous processes
kill "$PARENT_PID" 2>/dev/null || true
wait "$PARENT_PID" 2>/dev/null || true
kill "$ORCH_PID_D" 2>/dev/null || true
wait "$ORCH_PID_D" 2>/dev/null || true
rm -rf "${IPC_BASE:?}/"*

SESSION_E="test-ps-handle-00000005"
IPC_DIR_E="${IPC_BASE}/${SESSION_E}"
mkdir -p "$IPC_DIR_E"

# Launch orchestrator process
(sleep 300) &
ORCH_PID_E=$!
BGPIDS="$BGPIDS$ORCH_PID_E "

echo "$ORCH_PID_E" > "${IPC_DIR_E}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR_E}/orchestrator.spawned"

# Launch a "managed" worker process (simulates PPID=1 reparented Worker)
(sleep 300) &
MANAGED_PID=$!
BGPIDS="$BGPIDS$MANAGED_PID "

# Create handle file for issue 999
echo "$MANAGED_PID" > "${IPC_DIR_E}/handle-999.worker"

# ── Test 10: ps shows managed processes from handle files ──
# Expected output format: └── worker #999  PID=<pid>  <state>  (managed, PPID=<ppid>)
OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
assert_match "ps shows managed marker" '\(managed' "$OUTPUT"
assert_match "ps managed shows PID" "PID=${MANAGED_PID}" "$OUTPUT"

# ── Test 11: managed process shows issue number ──
assert_match "ps managed shows issue" "#999" "$OUTPUT"

# ── Test 12: managed process shows type ──
assert_match "ps managed shows worker type" "worker #999" "$OUTPUT"

# ── Test 13: managed process not duplicated with child processes ──
# Create an orchestrator with a child that is also a handle (should not be shown twice)
kill "$ORCH_PID_E" 2>/dev/null || true
wait "$ORCH_PID_E" 2>/dev/null || true
kill "$MANAGED_PID" 2>/dev/null || true
wait "$MANAGED_PID" 2>/dev/null || true
rm -rf "${IPC_BASE:?}/"*

SESSION_F="test-ps-dedup-00000006"
IPC_DIR_F="${IPC_BASE}/${SESSION_F}"
mkdir -p "$IPC_DIR_F"

# Launch parent that spawns a child
bash -c 'sleep 300 & wait' &
PARENT_PID_F=$!
BGPIDS="$BGPIDS$PARENT_PID_F "
sleep 0.3  # Give child time to spawn

echo "$PARENT_PID_F" > "${IPC_DIR_F}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR_F}/orchestrator.spawned"

# Get the child PID and create a handle for it (simulate child that is also managed)
CHILD_PID_F=$(pgrep -P "$PARENT_PID_F" 2>/dev/null | head -1)
if [[ -n "$CHILD_PID_F" ]]; then
  echo "$CHILD_PID_F" > "${IPC_DIR_F}/handle-888.worker"

  OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
  # The child should appear as a child process, NOT as managed
  MANAGED_COUNT=$(echo "$OUTPUT" | grep -c '(managed' || true)
  assert_eq "ps child+handle not shown as managed" "0" "$MANAGED_COUNT"
else
  echo "  SKIP: could not get child PID for dedup test"
fi

# ── Test 14: managed process with dead PID is not shown ──
kill "$PARENT_PID_F" 2>/dev/null || true
wait "$PARENT_PID_F" 2>/dev/null || true
rm -rf "${IPC_BASE:?}/"*

SESSION_G="test-ps-dead-handle-00000007"
IPC_DIR_G="${IPC_BASE}/${SESSION_G}"
mkdir -p "$IPC_DIR_G"

(sleep 300) &
ORCH_PID_G=$!
BGPIDS="$BGPIDS$ORCH_PID_G "

echo "$ORCH_PID_G" > "${IPC_DIR_G}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR_G}/orchestrator.spawned"

# Create handle file with a dead PID
echo "99999" > "${IPC_DIR_G}/handle-777.worker"

OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
MANAGED_COUNT=$(echo "$OUTPUT" | grep -c '(managed' || true)
assert_eq "ps dead managed not shown" "0" "$MANAGED_COUNT"

# ── Test 15: multiple managed processes (worker + reviewer) ──
kill "$ORCH_PID_G" 2>/dev/null || true
wait "$ORCH_PID_G" 2>/dev/null || true
rm -rf "${IPC_BASE:?}/"*

SESSION_H="test-ps-multi-handle-00000008"
IPC_DIR_H="${IPC_BASE}/${SESSION_H}"
mkdir -p "$IPC_DIR_H"

(sleep 300) &
ORCH_PID_H=$!
BGPIDS="$BGPIDS$ORCH_PID_H "

echo "$ORCH_PID_H" > "${IPC_DIR_H}/orchestrator.pid"
echo "$(date +%s)" > "${IPC_DIR_H}/orchestrator.spawned"

# Two managed processes for the same issue (worker + reviewer)
(sleep 300) &
MANAGED_W=$!
BGPIDS="$BGPIDS$MANAGED_W "

(sleep 300) &
MANAGED_R=$!
BGPIDS="$BGPIDS$MANAGED_R "

echo "$MANAGED_W" > "${IPC_DIR_H}/handle-555.worker"
echo "$MANAGED_R" > "${IPC_DIR_H}/handle-555.reviewer"

OUTPUT=$(bash "$ORCHCTL" ps 2>/dev/null)
MANAGED_COUNT=$(echo "$OUTPUT" | grep -c '(managed' || true)
assert_eq "ps shows both worker and reviewer" "2" "$MANAGED_COUNT"
assert_match "ps multi-managed shows worker" "worker #555" "$OUTPUT"
assert_match "ps multi-managed shows reviewer" "reviewer #555" "$OUTPUT"

report_results
