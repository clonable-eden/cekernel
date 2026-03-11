#!/usr/bin/env bash
# test-orchctrl-gc.sh — Tests for orchctrl.sh gc command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCHCTRL="${CEKERNEL_DIR}/scripts/orchestrator/orchctrl.sh"

echo "test: orchctrl gc"

# ── Isolated IPC/locks base for test isolation ──
IPC_BASE=$(mktemp -d /tmp/cekernel-test-orchctrl-gc.XXXXXX)
export CEKERNEL_IPC_BASE="$IPC_BASE"
export CEKERNEL_VAR_DIR=$(mktemp -d /tmp/cekernel-test-gc-var.XXXXXX)

# ── Cleanup ──
cleanup() {
  rm -rf "$IPC_BASE" "$CEKERNEL_VAR_DIR"
}
trap cleanup EXIT

# ══════════════════════════════════════════════
# gc command — basic behavior
# ══════════════════════════════════════════════

# ── Test 1: gc with no stale resources → exit 0, "nothing to clean" ──
mkdir -p "${IPC_BASE}/session-gc-01"
OUTPUT=$(bash "$ORCHCTRL" gc 2>&1)
EXIT_CODE=$?
assert_eq "gc no stale resources: exit 0" "0" "$EXIT_CODE"
assert_match "gc no stale: nothing to clean" "nothing to clean" "$OUTPUT"

# ══════════════════════════════════════════════
# gc — stale lock cleanup
# ══════════════════════════════════════════════

# ── Test 2: gc removes stale lock (dead PID) ──
LOCK_DIR="${CEKERNEL_VAR_DIR}/locks/testhash123/42.lock"
mkdir -p "$LOCK_DIR"
echo "99999999" > "${LOCK_DIR}/pid"
OUTPUT=$(bash "$ORCHCTRL" gc 2>&1)
assert_not_exists "gc removes stale lock dir" "$LOCK_DIR"

# ── Test 3: gc preserves lock with live PID ──
LOCK_DIR_LIVE="${CEKERNEL_VAR_DIR}/locks/testhash123/43.lock"
mkdir -p "$LOCK_DIR_LIVE"
echo "$$" > "${LOCK_DIR_LIVE}/pid"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_dir_exists "gc preserves live lock" "$LOCK_DIR_LIVE"
# Cleanup
rm -rf "$LOCK_DIR_LIVE"

# ── Test 4: gc removes lock dir without PID file ──
LOCK_DIR_NOPID="${CEKERNEL_VAR_DIR}/locks/testhash123/44.lock"
mkdir -p "$LOCK_DIR_NOPID"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes lock without pid" "$LOCK_DIR_NOPID"

# ══════════════════════════════════════════════
# gc — orphan IPC file cleanup
# ══════════════════════════════════════════════

# ── Test 5: gc removes orphan state file (no FIFO) ──
SESSION_DIR="${IPC_BASE}/session-gc-02"
mkdir -p "$SESSION_DIR"
echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${SESSION_DIR}/worker-50.state"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan state file" "${SESSION_DIR}/worker-50.state"

# ── Test 6: gc preserves state file with active FIFO ──
SESSION_DIR2="${IPC_BASE}/session-gc-03"
mkdir -p "$SESSION_DIR2"
mkfifo "${SESSION_DIR2}/worker-51"
echo "RUNNING:2026-02-28T10:00:00Z:working" > "${SESSION_DIR2}/worker-51.state"
echo "10" > "${SESSION_DIR2}/worker-51.priority"
echo "worker" > "${SESSION_DIR2}/worker-51.type"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_file_exists "gc preserves state with FIFO" "${SESSION_DIR2}/worker-51.state"
assert_file_exists "gc preserves priority with FIFO" "${SESSION_DIR2}/worker-51.priority"
assert_file_exists "gc preserves type with FIFO" "${SESSION_DIR2}/worker-51.type"

# ── Test 7: gc removes orphan priority/type/signal files ──
mkdir -p "$SESSION_DIR"
echo "5" > "${SESSION_DIR}/worker-50.priority"
echo "worker" > "${SESSION_DIR}/worker-50.type"
echo "TERM" > "${SESSION_DIR}/worker-50.signal"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan priority" "${SESSION_DIR}/worker-50.priority"
assert_not_exists "gc removes orphan type" "${SESSION_DIR}/worker-50.type"
assert_not_exists "gc removes orphan signal" "${SESSION_DIR}/worker-50.signal"

# ══════════════════════════════════════════════
# gc — empty session directory cleanup
# ══════════════════════════════════════════════

# ── Test 8: gc removes empty session directory ──
EMPTY_SESSION="${IPC_BASE}/session-gc-empty"
mkdir -p "$EMPTY_SESSION"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes empty session dir" "$EMPTY_SESSION"

# ── Test 9: gc preserves non-empty session directory ──
assert_dir_exists "gc preserves non-empty session" "$SESSION_DIR2"

# ══════════════════════════════════════════════
# gc — orphan handle/payload/log cleanup
# ══════════════════════════════════════════════

# ── Test 10: gc removes orphan handle file ──
mkdir -p "$SESSION_DIR"
echo "12345" > "${SESSION_DIR}/handle-50.worker"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan handle file" "${SESSION_DIR}/handle-50.worker"

# ── Test 11: gc removes orphan payload file ──
mkdir -p "$SESSION_DIR"
echo "base64data" > "${SESSION_DIR}/payload-50.b64"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan payload" "${SESSION_DIR}/payload-50.b64"

# ── Test 12: gc removes orphan log files ──
mkdir -p "$SESSION_DIR"
mkdir -p "${SESSION_DIR}/logs"
echo "log data" > "${SESSION_DIR}/logs/worker-50.log"
echo "stdout data" > "${SESSION_DIR}/logs/worker-50.stdout.log"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan log" "${SESSION_DIR}/logs/worker-50.log"
assert_not_exists "gc removes orphan stdout log" "${SESSION_DIR}/logs/worker-50.stdout.log"

# ══════════════════════════════════════════════
# gc --dry-run
# ══════════════════════════════════════════════

# ── Test 13: --dry-run shows what would be cleaned but doesn't delete ──
LOCK_DIR_DRY="${CEKERNEL_VAR_DIR}/locks/testhash456/60.lock"
mkdir -p "$LOCK_DIR_DRY"
echo "99999999" > "${LOCK_DIR_DRY}/pid"
OUTPUT=$(bash "$ORCHCTRL" gc --dry-run 2>&1)
assert_dir_exists "dry-run preserves stale lock" "$LOCK_DIR_DRY"
assert_match "dry-run output indicates would clean" "dry-run" "$OUTPUT"
# Cleanup
rm -rf "${CEKERNEL_VAR_DIR}/locks/testhash456"

# ══════════════════════════════════════════════
# gc — empty repo-hash directory cleanup
# ══════════════════════════════════════════════

# ── Test 14: gc removes empty repo-hash directory under locks ──
EMPTY_HASH_DIR="${CEKERNEL_VAR_DIR}/locks/emptyhash000"
mkdir -p "$EMPTY_HASH_DIR"
bash "$ORCHCTRL" gc >/dev/null 2>&1
assert_not_exists "gc removes empty repo-hash dir" "$EMPTY_HASH_DIR"

# ══════════════════════════════════════════════
# gc — output summary
# ══════════════════════════════════════════════

# ── Test 15: gc output includes summary count ──
# Create some stale resources
LOCK_DIR_SUM="${CEKERNEL_VAR_DIR}/locks/testhash789/70.lock"
mkdir -p "$LOCK_DIR_SUM"
echo "99999999" > "${LOCK_DIR_SUM}/pid"
mkdir -p "$SESSION_DIR"
echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${SESSION_DIR}/worker-70.state"
OUTPUT=$(bash "$ORCHCTRL" gc 2>&1)
assert_match "gc output includes cleaned count" "cleaned" "$OUTPUT"

report_results
