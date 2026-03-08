#!/usr/bin/env bash
# test-session-isolation.sh — FIFO isolation test between different sessions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: session-isolation"

ISSUE_NUMBER=10

# ── Session A ──
CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}"
SESSION_A="test-isolation-aaaaaaaa"
SESSION_A_DIR="${CEKERNEL_VAR_DIR}/ipc/${SESSION_A}"
mkdir -p "$SESSION_A_DIR"
FIFO_A="${SESSION_A_DIR}/worker-${ISSUE_NUMBER}"
mkfifo "$FIFO_A"

# ── Session B (same issue number) ──
SESSION_B="test-isolation-bbbbbbbb"
SESSION_B_DIR="${CEKERNEL_VAR_DIR}/ipc/${SESSION_B}"
mkdir -p "$SESSION_B_DIR"
FIFO_B="${SESSION_B_DIR}/worker-${ISSUE_NUMBER}"
mkfifo "$FIFO_B"

# ── Test: Same issue number in different sessions should not collide ──
assert_fifo_exists "Session A FIFO exists" "$FIFO_A"
assert_fifo_exists "Session B FIFO exists" "$FIFO_B"
assert_eq "FIFOs are at different paths" "1" "$([[ "$FIFO_A" != "$FIFO_B" ]] && echo 1 || echo 0)"

# ── Test: Write/read data independently for each session ──
RESULT_A=$(mktemp)
RESULT_B=$(mktemp)

# Readers in background
(cat "$FIFO_A" > "$RESULT_A") &
PID_A=$!
(cat "$FIFO_B" > "$RESULT_B") &
PID_B=$!

# Writers in background (FIFO open blocks until reader is ready)
echo '{"session":"A"}' > "$FIFO_A" &
echo '{"session":"B"}' > "$FIFO_B" &

# Wait with timeout to avoid hanging
WAITED=0
while [[ $WAITED -lt 50 ]]; do
  kill -0 "$PID_A" 2>/dev/null || kill -0 "$PID_B" 2>/dev/null || break
  sleep 0.1
  WAITED=$((WAITED + 1))
done
kill "$PID_A" "$PID_B" 2>/dev/null || true
wait 2>/dev/null || true

assert_match "Session A received its own data" '"session":"A"' "$(cat "$RESULT_A")"
assert_match "Session B received its own data" '"session":"B"' "$(cat "$RESULT_B")"

# Cleanup
rm -f "$FIFO_A" "$FIFO_B" "$RESULT_A" "$RESULT_B"
rmdir "$SESSION_A_DIR" 2>/dev/null || true
rmdir "$SESSION_B_DIR" 2>/dev/null || true

report_results
