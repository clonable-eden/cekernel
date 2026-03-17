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

# ── Test 7b: ls output contains type from .type file ──
echo "worker" > "${IPC_A}/worker-10.type"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls output contains type worker" '"type":"worker"' "$OUTPUT"

# ── Test 7c: ls output with reviewer type ──
mkfifo "${IPC_A}/worker-11"
echo "RUNNING:2026-02-28T10:00:00Z:reviewing" > "${IPC_A}/worker-11.state"
echo "10" > "${IPC_A}/worker-11.priority"
echo "reviewer" > "${IPC_A}/worker-11.type"
OUTPUT_11=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":11')
assert_match "ls output contains type reviewer" '"type":"reviewer"' "$OUTPUT_11"
# Cleanup test worker-11
rm -f "${IPC_A}/worker-11" "${IPC_A}/worker-11.state" "${IPC_A}/worker-11.priority" "${IPC_A}/worker-11.type"

# ── Test 7d: ls output missing type file defaults to unknown ──
rm -f "${IPC_A}/worker-10.type"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls output missing type shows unknown" '"type":"unknown"' "$OUTPUT"
# Restore type file for subsequent tests
echo "worker" > "${IPC_A}/worker-10.type"

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
# inspect command
# ══════════════════════════════════════════════

# ── Test 27: inspect output contains state and priority ──
echo "RUNNING:2026-02-28T10:00:00Z:implementing" > "${IPC_A}/worker-10.state"
echo "5" > "${IPC_A}/worker-10.priority"
OUTPUT=$(bash "$ORCHCTRL" inspect 10 --session "$SESSION_A" 2>/dev/null)
assert_match "inspect contains state" '"state":"RUNNING"' "$OUTPUT"
assert_match "inspect contains priority" '"priority":5' "$OUTPUT"
assert_match "inspect contains session" "$SESSION_A" "$OUTPUT"

# ── Test 27b: inspect output contains type ──
echo "worker" > "${IPC_A}/worker-10.type"
OUTPUT=$(bash "$ORCHCTRL" inspect 10 --session "$SESSION_A" 2>/dev/null)
assert_match "inspect contains type" '"type":"worker"' "$OUTPUT"

# ── Test 27c: inspect output contains detail and timestamp ──
echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${IPC_A}/worker-10.state"
OUTPUT=$(bash "$ORCHCTRL" inspect 10 --session "$SESSION_A" 2>/dev/null)
assert_match "inspect contains detail" '"detail":"phase1:implement"' "$OUTPUT"
assert_match "inspect contains timestamp" '"timestamp":"2026-02-28T10:00:00Z"' "$OUTPUT"

# ══════════════════════════════════════════════
# detect_backend: metadata file
# ══════════════════════════════════════════════

# ── Test 28a: ls output contains backend from metadata file (wezterm) ──
echo "wezterm" > "${IPC_A}/worker-10.backend"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls backend metadata: wezterm" '"backend":"wezterm"' "$OUTPUT"

# ── Test 28b: ls output contains backend from metadata file (headless) ──
echo "headless" > "${IPC_A}/worker-10.backend"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls backend metadata: headless" '"backend":"headless"' "$OUTPUT"

# ── Test 28c: ls output contains backend from metadata file (tmux) ──
echo "tmux" > "${IPC_A}/worker-10.backend"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls backend metadata: tmux" '"backend":"tmux"' "$OUTPUT"

# ── Test 28d: ls backend prefers metadata file over stdout.log heuristic ──
# Even if stdout.log exists (which would trigger old "headless" heuristic),
# metadata file takes precedence.
mkdir -p "${IPC_A}/logs"
touch "${IPC_A}/logs/worker-10.stdout.log"
echo "wezterm" > "${IPC_A}/worker-10.backend"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls backend: metadata overrides stdout.log heuristic" '"backend":"wezterm"' "$OUTPUT"
rm -f "${IPC_A}/logs/worker-10.stdout.log"
rmdir "${IPC_A}/logs" 2>/dev/null || true

# ── Test 28e: ls backend falls back to heuristic when metadata file absent ──
rm -f "${IPC_A}/worker-10.backend"
# No handle file → should return "unknown"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls backend fallback: no handle → unknown" '"backend":"unknown"' "$OUTPUT"

# ── Test 28f: inspect output contains backend from metadata file ──
echo "headless" > "${IPC_A}/worker-10.backend"
OUTPUT=$(bash "$ORCHCTRL" inspect 10 --session "$SESSION_A" 2>/dev/null)
assert_match "inspect backend metadata: headless" '"backend":"headless"' "$OUTPUT"
rm -f "${IPC_A}/worker-10.backend"

# ══════════════════════════════════════════════
# repo metadata file
# ══════════════════════════════════════════════

# ── Test 30: ls repo field reads from metadata file ──
echo "clonable-eden/test-repo" > "${IPC_A}/repo"
echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${IPC_A}/worker-10.state"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls repo from metadata file" '"repo":"clonable-eden/test-repo"' "$OUTPUT"
rm -f "${IPC_A}/repo"

# ── Test 31: ls repo field falls back to session ID prefix without metadata file ──
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls repo fallback to session ID prefix" '"repo":"test-orchctrl-repo1"' "$OUTPUT"

# ── Test 32: ls repo field from metadata file with whitespace trimmed ──
printf "  clonable-eden/another-repo  \n" > "${IPC_A}/repo"
OUTPUT=$(bash "$ORCHCTRL" ls 2>/dev/null | grep '"issue":10')
assert_match "ls repo metadata trims whitespace" '"repo":"clonable-eden/another-repo"' "$OUTPUT"
rm -f "${IPC_A}/repo"

# ── Test 33: resolve_target repo filter matches org/repo from metadata ──
echo "clonable-eden/test-repo" > "${IPC_A}/repo"
EXIT_CODE=0
OUTPUT=$(bash "$ORCHCTRL" inspect "clonable-eden/test-repo:10" 2>/dev/null) || EXIT_CODE=$?
assert_eq "resolve_target org/repo filter: exit 0" "0" "$EXIT_CODE"
assert_match "resolve_target org/repo filter" '"issue":10' "$OUTPUT"
rm -f "${IPC_A}/repo"

# ── Test 34: resolve_target repo filter still works with short name (backward compat) ──
EXIT_CODE=0
OUTPUT=$(bash "$ORCHCTRL" inspect "test-orchctrl-repo1:10" 2>/dev/null) || EXIT_CODE=$?
assert_eq "resolve_target short repo filter (backward compat): exit 0" "0" "$EXIT_CODE"
assert_match "resolve_target short repo filter (backward compat)" '"issue":10' "$OUTPUT"

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
