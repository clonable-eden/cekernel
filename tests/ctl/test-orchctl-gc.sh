#!/usr/bin/env bash
# test-orchctl-gc.sh — Tests for orchctl.sh gc command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCHCTL="${CEKERNEL_DIR}/scripts/ctl/orchctl.sh"

echo "test: orchctl gc"

# ── Isolated IPC/locks base for test isolation ──
IPC_BASE=$(mktemp -d /tmp/cekernel-test-orchctl-gc.XXXXXX)
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
OUTPUT=$(bash "$ORCHCTL" gc 2>&1)
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
OUTPUT=$(bash "$ORCHCTL" gc 2>&1)
assert_not_exists "gc removes stale lock dir" "$LOCK_DIR"

# ── Test 3: gc preserves lock with live PID ──
LOCK_DIR_LIVE="${CEKERNEL_VAR_DIR}/locks/testhash123/43.lock"
mkdir -p "$LOCK_DIR_LIVE"
echo "$$" > "${LOCK_DIR_LIVE}/pid"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_dir_exists "gc preserves live lock" "$LOCK_DIR_LIVE"
# Cleanup
rm -rf "$LOCK_DIR_LIVE"

# ── Test 4: gc removes lock dir without PID file ──
LOCK_DIR_NOPID="${CEKERNEL_VAR_DIR}/locks/testhash123/44.lock"
mkdir -p "$LOCK_DIR_NOPID"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes lock without pid" "$LOCK_DIR_NOPID"

# ══════════════════════════════════════════════
# gc — orphan IPC file cleanup
# ══════════════════════════════════════════════

# ── Test 5: gc removes orphan state file (no FIFO) ──
SESSION_DIR="${IPC_BASE}/session-gc-02"
mkdir -p "$SESSION_DIR"
echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${SESSION_DIR}/worker-50.state"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan state file" "${SESSION_DIR}/worker-50.state"

# ── Test 6: gc preserves state file with active FIFO + live handle ──
SESSION_DIR2="${IPC_BASE}/session-gc-03"
mkdir -p "$SESSION_DIR2"
mkfifo "${SESSION_DIR2}/worker-51"
echo "RUNNING:2026-02-28T10:00:00Z:working" > "${SESSION_DIR2}/worker-51.state"
echo "10" > "${SESSION_DIR2}/worker-51.priority"
echo "worker" > "${SESSION_DIR2}/worker-51.type"
# A live handle (our own PID) makes this an active worker
echo "$$" > "${SESSION_DIR2}/handle-51.worker"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_file_exists "gc preserves state with FIFO" "${SESSION_DIR2}/worker-51.state"
assert_file_exists "gc preserves priority with FIFO" "${SESSION_DIR2}/worker-51.priority"
assert_file_exists "gc preserves type with FIFO" "${SESSION_DIR2}/worker-51.type"

# ── Test 7: gc removes orphan priority/type/signal files ──
mkdir -p "$SESSION_DIR"
echo "5" > "${SESSION_DIR}/worker-50.priority"
echo "worker" > "${SESSION_DIR}/worker-50.type"
echo "TERM" > "${SESSION_DIR}/worker-50.signal"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan priority" "${SESSION_DIR}/worker-50.priority"
assert_not_exists "gc removes orphan type" "${SESSION_DIR}/worker-50.type"
assert_not_exists "gc removes orphan signal" "${SESSION_DIR}/worker-50.signal"

# ══════════════════════════════════════════════
# gc — empty session directory cleanup
# ══════════════════════════════════════════════

# ── Test 8: gc removes empty session directory ──
EMPTY_SESSION="${IPC_BASE}/session-gc-empty"
mkdir -p "$EMPTY_SESSION"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes empty session dir" "$EMPTY_SESSION"

# ── Test 9: gc preserves non-empty session directory ──
assert_dir_exists "gc preserves non-empty session" "$SESSION_DIR2"

# ══════════════════════════════════════════════
# gc — orphan handle/payload/log cleanup
# ══════════════════════════════════════════════

# ── Test 10: gc removes orphan handle file ──
mkdir -p "$SESSION_DIR"
echo "12345" > "${SESSION_DIR}/handle-50.worker"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan handle file" "${SESSION_DIR}/handle-50.worker"

# ── Test 11: gc removes orphan payload file ──
mkdir -p "$SESSION_DIR"
echo "base64data" > "${SESSION_DIR}/payload-50.b64"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan payload" "${SESSION_DIR}/payload-50.b64"

# ── Test 12: gc removes orphan log files ──
mkdir -p "$SESSION_DIR"
mkdir -p "${SESSION_DIR}/logs"
echo "log data" > "${SESSION_DIR}/logs/worker-50.log"
echo "stdout data" > "${SESSION_DIR}/logs/worker-50.stdout.log"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes orphan log" "${SESSION_DIR}/logs/worker-50.log"
assert_not_exists "gc removes orphan stdout log" "${SESSION_DIR}/logs/worker-50.stdout.log"

# ══════════════════════════════════════════════
# gc — stale FIFO cleanup (issue #303)
# ══════════════════════════════════════════════

# ── Test 16: gc removes stale FIFO when TERMINATED + no handle ──
SESSION_DIR_STALE="${IPC_BASE}/session-gc-stale"
mkdir -p "$SESSION_DIR_STALE"
mkfifo "${SESSION_DIR_STALE}/worker-296"
echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${SESSION_DIR_STALE}/worker-296.state"
echo "worker" > "${SESSION_DIR_STALE}/worker-296.type"
echo "10" > "${SESSION_DIR_STALE}/worker-296.priority"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes stale FIFO (TERMINATED + no handle)" "${SESSION_DIR_STALE}/worker-296"
assert_not_exists "gc removes state for stale FIFO" "${SESSION_DIR_STALE}/worker-296.state"
assert_not_exists "gc removes type for stale FIFO" "${SESSION_DIR_STALE}/worker-296.type"
assert_not_exists "gc removes priority for stale FIFO" "${SESSION_DIR_STALE}/worker-296.priority"

# ── Test 17: gc removes stale FIFO when NEW + no handle + old (stale timeout) ──
SESSION_DIR_STALE2="${IPC_BASE}/session-gc-stale2"
mkdir -p "$SESSION_DIR_STALE2"
mkfifo "${SESSION_DIR_STALE2}/worker-297"
# State is NEW with old timestamp (>30 min ago)
echo "NEW:2026-02-28T01:00:00Z:spawning" > "${SESSION_DIR_STALE2}/worker-297.state"
echo "worker" > "${SESSION_DIR_STALE2}/worker-297.type"
# Override staleness: set CEKERNEL_GC_STALE_TIMEOUT=0 to force stale
CEKERNEL_GC_STALE_TIMEOUT=0 bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes stale FIFO (NEW + timeout)" "${SESSION_DIR_STALE2}/worker-297"
assert_not_exists "gc removes state for stale NEW FIFO" "${SESSION_DIR_STALE2}/worker-297.state"
assert_not_exists "gc removes type for stale NEW FIFO" "${SESSION_DIR_STALE2}/worker-297.type"

# ── Test 18: gc removes stale FIFO with handle but dead process ──
SESSION_DIR_STALE3="${IPC_BASE}/session-gc-stale3"
mkdir -p "$SESSION_DIR_STALE3"
mkfifo "${SESSION_DIR_STALE3}/worker-298"
echo "RUNNING:2026-02-28T10:00:00Z:working" > "${SESSION_DIR_STALE3}/worker-298.state"
echo "worker" > "${SESSION_DIR_STALE3}/worker-298.type"
# Create a handle file with a dead PID
echo "99999999" > "${SESSION_DIR_STALE3}/handle-298.worker"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes stale FIFO (dead handle PID)" "${SESSION_DIR_STALE3}/worker-298"
assert_not_exists "gc removes state for dead handle" "${SESSION_DIR_STALE3}/worker-298.state"
assert_not_exists "gc removes handle for dead process" "${SESSION_DIR_STALE3}/handle-298.worker"

# ── Test 19: gc preserves FIFO with live handle ──
SESSION_DIR_LIVE="${IPC_BASE}/session-gc-live"
mkdir -p "$SESSION_DIR_LIVE"
mkfifo "${SESSION_DIR_LIVE}/worker-299"
echo "RUNNING:2026-02-28T10:00:00Z:working" > "${SESSION_DIR_LIVE}/worker-299.state"
echo "worker" > "${SESSION_DIR_LIVE}/worker-299.type"
# Create a handle file with our own (live) PID
echo "$$" > "${SESSION_DIR_LIVE}/handle-299.worker"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_fifo_exists "gc preserves FIFO with live handle" "${SESSION_DIR_LIVE}/worker-299"
assert_file_exists "gc preserves state with live handle" "${SESSION_DIR_LIVE}/worker-299.state"
assert_file_exists "gc preserves handle with live process" "${SESSION_DIR_LIVE}/handle-299.worker"
# Cleanup
rm -f "${SESSION_DIR_LIVE}/worker-299" "${SESSION_DIR_LIVE}/worker-299.state" "${SESSION_DIR_LIVE}/worker-299.type" "${SESSION_DIR_LIVE}/handle-299.worker"
rmdir "$SESSION_DIR_LIVE" 2>/dev/null || true

# ── Test 20: gc --dry-run shows stale FIFO but doesn't remove it ──
SESSION_DIR_DRY="${IPC_BASE}/session-gc-stale-dry"
mkdir -p "$SESSION_DIR_DRY"
mkfifo "${SESSION_DIR_DRY}/worker-300"
echo "TERMINATED:2026-02-28T10:00:00Z:done" > "${SESSION_DIR_DRY}/worker-300.state"
OUTPUT=$(bash "$ORCHCTL" gc --dry-run 2>&1)
assert_fifo_exists "dry-run preserves stale FIFO" "${SESSION_DIR_DRY}/worker-300"
assert_match "dry-run mentions stale FIFO" "stale FIFO" "$OUTPUT"
# Cleanup the stale resources for subsequent tests
rm -f "${SESSION_DIR_DRY}/worker-300" "${SESSION_DIR_DRY}/worker-300.state"
rmdir "$SESSION_DIR_DRY" 2>/dev/null || true

# ══════════════════════════════════════════════
# gc --dry-run
# ══════════════════════════════════════════════

# ── Test 13: --dry-run shows what would be cleaned but doesn't delete ──
LOCK_DIR_DRY="${CEKERNEL_VAR_DIR}/locks/testhash456/60.lock"
mkdir -p "$LOCK_DIR_DRY"
echo "99999999" > "${LOCK_DIR_DRY}/pid"
OUTPUT=$(bash "$ORCHCTL" gc --dry-run 2>&1)
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
bash "$ORCHCTL" gc >/dev/null 2>&1
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
OUTPUT=$(bash "$ORCHCTL" gc 2>&1)
assert_match "gc output includes cleaned count" "cleaned" "$OUTPUT"

# ══════════════════════════════════════════════
# gc — stale orchestrator.pid cleanup (issue #513)
# ══════════════════════════════════════════════

# ── Test 21: gc removes orchestrator.pid when process is dead ──
SESSION_DIR_ORCH="${IPC_BASE}/session-gc-orch1"
mkdir -p "$SESSION_DIR_ORCH"
echo "99999999" > "${SESSION_DIR_ORCH}/orchestrator.pid"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes stale orchestrator.pid (dead PID)" "${SESSION_DIR_ORCH}/orchestrator.pid"

# ── Test 22: gc preserves orchestrator.pid when process is alive ──
SESSION_DIR_ORCH_LIVE="${IPC_BASE}/session-gc-orch2"
mkdir -p "$SESSION_DIR_ORCH_LIVE"
echo "$$" > "${SESSION_DIR_ORCH_LIVE}/orchestrator.pid"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_file_exists "gc preserves live orchestrator.pid" "${SESSION_DIR_ORCH_LIVE}/orchestrator.pid"
# Cleanup
rm -f "${SESSION_DIR_ORCH_LIVE}/orchestrator.pid"
rmdir "$SESSION_DIR_ORCH_LIVE" 2>/dev/null || true

# ── Test 23: gc removes orchestrator.spawned alongside stale orchestrator.pid ──
SESSION_DIR_ORCH3="${IPC_BASE}/session-gc-orch3"
mkdir -p "$SESSION_DIR_ORCH3"
echo "99999999" > "${SESSION_DIR_ORCH3}/orchestrator.pid"
echo "1711000000" > "${SESSION_DIR_ORCH3}/orchestrator.spawned"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes orchestrator.spawned with stale pid" "${SESSION_DIR_ORCH3}/orchestrator.spawned"
assert_not_exists "gc removes orchestrator.pid with spawned" "${SESSION_DIR_ORCH3}/orchestrator.pid"

# ── Test 24: gc removes repo file alongside stale orchestrator.pid ──
SESSION_DIR_ORCH4="${IPC_BASE}/session-gc-orch4"
mkdir -p "$SESSION_DIR_ORCH4"
echo "99999999" > "${SESSION_DIR_ORCH4}/orchestrator.pid"
echo "my-repo" > "${SESSION_DIR_ORCH4}/repo"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes repo file with stale pid" "${SESSION_DIR_ORCH4}/repo"

# ── Test 25: gc --dry-run shows stale orchestrator.pid but doesn't remove ──
SESSION_DIR_ORCH5="${IPC_BASE}/session-gc-orch5"
mkdir -p "$SESSION_DIR_ORCH5"
echo "99999999" > "${SESSION_DIR_ORCH5}/orchestrator.pid"
echo "1711000000" > "${SESSION_DIR_ORCH5}/orchestrator.spawned"
OUTPUT=$(bash "$ORCHCTL" gc --dry-run 2>&1)
assert_file_exists "dry-run preserves stale orchestrator.pid" "${SESSION_DIR_ORCH5}/orchestrator.pid"
assert_file_exists "dry-run preserves stale orchestrator.spawned" "${SESSION_DIR_ORCH5}/orchestrator.spawned"
assert_match "dry-run mentions orchestrator.pid" "orchestrator.pid" "$OUTPUT"
# Cleanup
rm -f "${SESSION_DIR_ORCH5}/orchestrator.pid" "${SESSION_DIR_ORCH5}/orchestrator.spawned"
rmdir "$SESSION_DIR_ORCH5" 2>/dev/null || true

# ── Test 26: gc removes empty session dir after orchestrator metadata cleanup ──
SESSION_DIR_ORCH6="${IPC_BASE}/session-gc-orch6"
mkdir -p "$SESSION_DIR_ORCH6"
echo "99999999" > "${SESSION_DIR_ORCH6}/orchestrator.pid"
echo "1711000000" > "${SESSION_DIR_ORCH6}/orchestrator.spawned"
bash "$ORCHCTL" gc >/dev/null 2>&1
assert_not_exists "gc removes empty session dir after orch cleanup" "${SESSION_DIR_ORCH6}"

report_results
