#!/usr/bin/env bash
# test-orchctrl.sh — Tests for orchctrl.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCHCTRL="${CEKERNEL_DIR}/scripts/orchestrator/orchctrl.sh"

echo "test: orchctrl"

# ── Isolated IPC base for test isolation ──
IPC_BASE=$(mktemp -d /tmp/cekernel-test-orchctrl.XXXXXX)
export CEKERNEL_IPC_BASE="$IPC_BASE"

# ── Test sessions ──
SESSION_A="test-orchctrl-repo1-00000001"
SESSION_B="test-orchctrl-repo2-00000002"
IPC_A="${IPC_BASE}/${SESSION_A}"
IPC_B="${IPC_BASE}/${SESSION_B}"

# ── Cleanup ──
cleanup() {
  rm -rf "$IPC_BASE"
}
trap cleanup EXIT

# ══════════════════════════════════════════════
# ls command
# ══════════════════════════════════════════════

# ── Test 1: ls with no sessions → "no workers." ──
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null)
assert_eq "ls no sessions: no workers." "no workers." "$OUTPUT"

# ── Test 2: ls with session but no workers → "no workers." ──
mkdir -p "$IPC_A"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null)
assert_eq "ls empty session: no workers." "no workers." "$OUTPUT"

# ── Test 3: ls with one worker → JSON line ──
mkfifo "${IPC_A}/worker-10"
echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${IPC_A}/worker-10.state"
echo "10" > "${IPC_A}/worker-10.priority"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null)
LINE_COUNT=$(echo "$OUTPUT" | grep -c '"issue"' || true)
assert_eq "ls one worker: one JSON line" "1" "$LINE_COUNT"

# ── Test 4: ls output contains session ID ──
assert_match "ls output contains session" "$SESSION_A" "$OUTPUT"

# ── Test 5: ls output contains issue number ──
assert_match "ls output contains issue 10" '"issue":10' "$OUTPUT"

# ── Test 6: ls output contains state ──
assert_match "ls output contains state RUNNING" '"state":"RUNNING"' "$OUTPUT"

# ── Test 7: ls output contains priority ──
assert_match "ls output contains priority" '"priority":10' "$OUTPUT"

# ── Test 8: ls across multiple sessions ──
mkdir -p "$IPC_B"
mkfifo "${IPC_B}/worker-20"
echo "WAITING:2026-02-28T10:00:00Z:ci-check" > "${IPC_B}/worker-20.state"
echo "5" > "${IPC_B}/worker-20.priority"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null)
LINE_COUNT=$(echo "$OUTPUT" | grep -c '"issue"' || true)
assert_eq "ls multiple sessions: two JSON lines" "2" "$LINE_COUNT"

# ══════════════════════════════════════════════
# Target resolution
# ══════════════════════════════════════════════

# ── Test 9: Unique issue → resolves ──
OUTPUT=$(bash "$ORCHCTRL" inspect 10 2>/dev/null)
assert_match "resolve unique issue 10" '"issue":10' "$OUTPUT"

# ── Test 10: Non-existent issue → error ──
EXIT_CODE=0
bash "$ORCHCTRL" inspect 999 2>/dev/null || EXIT_CODE=$?
assert_eq "resolve non-existent issue: error" "1" "$EXIT_CODE"

# ── Test 11: Ambiguous issue → error ──
mkfifo "${IPC_B}/worker-10"
echo "RUNNING:2026-02-28T10:00:00Z:test" > "${IPC_B}/worker-10.state"
EXIT_CODE=0
OUTPUT=$(bash "$ORCHCTRL" inspect 10 2>&1) || EXIT_CODE=$?
assert_eq "resolve ambiguous issue: error" "1" "$EXIT_CODE"
assert_match "ambiguous error shows candidates" "ambiguous" "$OUTPUT"
rm -f "${IPC_B}/worker-10" "${IPC_B}/worker-10.state"

# ── Test 12: repo:issue filter → resolves ──
OUTPUT=$(bash "$ORCHCTRL" inspect test-orchctrl-repo1:10 2>/dev/null)
assert_match "resolve repo:issue" '"issue":10' "$OUTPUT"
assert_match "resolve repo:issue correct session" "$SESSION_A" "$OUTPUT"

# ── Test 13: --session explicit → resolves ──
OUTPUT=$(bash "$ORCHCTRL" inspect 10 --session "$SESSION_A" 2>/dev/null)
assert_match "resolve --session explicit" '"issue":10' "$OUTPUT"
assert_match "resolve --session correct session" "$SESSION_A" "$OUTPUT"

# ── Test 14: --session with wrong issue → error ──
EXIT_CODE=0
bash "$ORCHCTRL" inspect 999 --session "$SESSION_A" 2>/dev/null || EXIT_CODE=$?
assert_eq "resolve --session wrong issue: error" "1" "$EXIT_CODE"

# ══════════════════════════════════════════════
# term command
# ══════════════════════════════════════════════

# ── Test 15: term creates TERM signal file ──
bash "$ORCHCTRL" term 10 --session "$SESSION_A" 2>/dev/null
SIGNAL_FILE="${IPC_A}/worker-10.signal"
assert_file_exists "term creates signal file" "$SIGNAL_FILE"
CONTENT=$(cat "$SIGNAL_FILE")
assert_eq "term signal file contains TERM" "TERM" "$CONTENT"
rm -f "$SIGNAL_FILE"

# ══════════════════════════════════════════════
# suspend command
# ══════════════════════════════════════════════

# ── Test 16: suspend RUNNING worker → creates SUSPEND signal ──
echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${IPC_A}/worker-10.state"
bash "$ORCHCTRL" suspend 10 --session "$SESSION_A" 2>/dev/null
SIGNAL_FILE="${IPC_A}/worker-10.signal"
assert_file_exists "suspend creates signal file" "$SIGNAL_FILE"
CONTENT=$(cat "$SIGNAL_FILE")
assert_eq "suspend signal file contains SUSPEND" "SUSPEND" "$CONTENT"
rm -f "$SIGNAL_FILE"

# ── Test 17: suspend TERMINATED worker → error ──
echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${IPC_A}/worker-10.state"
EXIT_CODE=0
bash "$ORCHCTRL" suspend 10 --session "$SESSION_A" 2>/dev/null || EXIT_CODE=$?
assert_eq "suspend TERMINATED worker: error" "1" "$EXIT_CODE"
assert_not_exists "suspend TERMINATED: no signal file" "${IPC_A}/worker-10.signal"

# ══════════════════════════════════════════════
# resume command
# ══════════════════════════════════════════════

# ── Test 18: resume SUSPENDED worker → changes state to READY ──
echo "SUSPENDED:2026-02-28T10:00:00Z:checkpoint-saved" > "${IPC_A}/worker-10.state"
bash "$ORCHCTRL" resume 10 --session "$SESSION_A" 2>/dev/null
STATE_CONTENT=$(cat "${IPC_A}/worker-10.state")
assert_match "resume changes state to READY" "^READY:" "$STATE_CONTENT"

# ── Test 19: resume RUNNING worker → error ──
echo "RUNNING:2026-02-28T10:00:00Z:working" > "${IPC_A}/worker-10.state"
EXIT_CODE=0
bash "$ORCHCTRL" resume 10 --session "$SESSION_A" 2>/dev/null || EXIT_CODE=$?
assert_eq "resume RUNNING worker: error" "1" "$EXIT_CODE"

# ══════════════════════════════════════════════
# nice command
# ══════════════════════════════════════════════

# ── Test 20: nice changes priority ──
echo "RUNNING:2026-02-28T10:00:00Z:working" > "${IPC_A}/worker-10.state"
OUTPUT=$(bash "$ORCHCTRL" nice 10 high --session "$SESSION_A" 2>/dev/null)
PRIORITY_CONTENT=$(cat "${IPC_A}/worker-10.priority")
assert_eq "nice changes priority to high (5)" "5" "$(echo "$PRIORITY_CONTENT" | tr -d '[:space:]')"

# ── Test 21: nice with numeric value ──
OUTPUT=$(bash "$ORCHCTRL" nice 10 3 --session "$SESSION_A" 2>/dev/null)
PRIORITY_CONTENT=$(cat "${IPC_A}/worker-10.priority")
assert_eq "nice changes priority to 3" "3" "$(echo "$PRIORITY_CONTENT" | tr -d '[:space:]')"

# ── Test 22: nice with invalid priority → error ──
EXIT_CODE=0
bash "$ORCHCTRL" nice 10 invalid --session "$SESSION_A" 2>/dev/null || EXIT_CODE=$?
assert_eq "nice invalid priority: error" "1" "$EXIT_CODE"

# ══════════════════════════════════════════════
# kill command
# ══════════════════════════════════════════════

# ── Test 23: kill marks worker as TERMINATED ──
echo "RUNNING:2026-02-28T10:00:00Z:working" > "${IPC_A}/worker-10.state"
bash "$ORCHCTRL" kill 10 --session "$SESSION_A" 2>/dev/null
STATE_CONTENT=$(cat "${IPC_A}/worker-10.state")
assert_match "kill marks worker as TERMINATED" "^TERMINATED:" "$STATE_CONTENT"
assert_match "kill detail says killed" ":killed$" "$STATE_CONTENT"

# ══════════════════════════════════════════════
# log command
# ══════════════════════════════════════════════

# ── Test 24: log shows log content ──
mkdir -p "${IPC_A}/logs"
echo "test log line 1" > "${IPC_A}/logs/worker-10.log"
echo "test log line 2" >> "${IPC_A}/logs/worker-10.log"
OUTPUT=$(bash "$ORCHCTRL" log 10 --session "$SESSION_A" 2>/dev/null)
assert_match "log shows content" "test log line 1" "$OUTPUT"

# ── Test 25: log prefers stdout.log for headless ──
echo "headless output" > "${IPC_A}/logs/worker-10.stdout.log"
OUTPUT=$(bash "$ORCHCTRL" log 10 --session "$SESSION_A" 2>/dev/null)
assert_match "log prefers stdout.log" "headless output" "$OUTPUT"
rm -f "${IPC_A}/logs/worker-10.stdout.log"

# ── Test 26: log missing → error ──
rm -rf "${IPC_A}/logs"
EXIT_CODE=0
bash "$ORCHCTRL" log 10 --session "$SESSION_A" 2>/dev/null || EXIT_CODE=$?
assert_eq "log missing: error" "1" "$EXIT_CODE"

# ══════════════════════════════════════════════
# inspect command
# ══════════════════════════════════════════════

# ── Test 27: inspect output contains state and priority ──
echo "RUNNING:2026-02-28T10:00:00Z:implementing" > "${IPC_A}/worker-10.state"
echo "5" > "${IPC_A}/worker-10.priority"
OUTPUT=$(bash "$ORCHCTRL" inspect 10 --session "$SESSION_A" 2>/dev/null)
assert_match "inspect contains state" '"state":"RUNNING"' "$OUTPUT"
assert_match "inspect contains priority" '"priority":5' "$OUTPUT"
assert_match "inspect contains session" "$SESSION_A" "$OUTPUT"

# ══════════════════════════════════════════════
# usage / no command
# ══════════════════════════════════════════════

# ── Test 28: no command → usage + exit 1 ──
EXIT_CODE=0
bash "$ORCHCTRL" 2>/dev/null || EXIT_CODE=$?
assert_eq "no command: exit 1" "1" "$EXIT_CODE"

# ── Test 29: unknown command → usage + exit 1 ──
EXIT_CODE=0
bash "$ORCHCTRL" foobar 2>/dev/null || EXIT_CODE=$?
assert_eq "unknown command: exit 1" "1" "$EXIT_CODE"

report_results
