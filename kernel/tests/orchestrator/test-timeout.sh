#!/usr/bin/env bash
# test-timeout.sh — watch-workers タイムアウト機構テスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: timeout"

export SESSION_ID="test-timeout-00000001"
source "${KERNEL_DIR}/scripts/shared/session-id.sh"

ISSUE=99

cleanup() {
  rm -f "${SESSION_IPC_DIR}/worker-${ISSUE}"
  rmdir "$SESSION_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$SESSION_IPC_DIR"
mkfifo "${SESSION_IPC_DIR}/worker-${ISSUE}"

# ── Test 1: タイムアウトで適切な JSON が返る ──
RESULT_FILE=$(mktemp)

# 2秒タイムアウトで watch-workers を起動（Writer は書き込まない）
KERNEL_WORKER_TIMEOUT=2 \
  bash "${KERNEL_DIR}/scripts/orchestrator/watch-workers.sh" "$ISSUE" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# 完了をポーリング（最大 10 秒）
WATCH_DONE=0
for _ in $(seq 1 100); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

wait "$WATCH_PID" 2>/dev/null || true

assert_eq "watch-workers exited within timeout" "1" "$WATCH_DONE"

RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Timeout status in result" '"status":"timeout"' "$RESULT"
assert_match "Issue number in result" '"issue":99' "$RESULT"
assert_match "Timeout detail in result" 'No response within' "$RESULT"

# ── Test 2: 正常完了はタイムアウト前に返る ──
# FIFO を再作成（Test 1 の watch_one で削除済み）
mkfifo "${SESSION_IPC_DIR}/worker-${ISSUE}"

RESULT_FILE=$(mktemp)

KERNEL_WORKER_TIMEOUT=10 \
  bash "${KERNEL_DIR}/scripts/orchestrator/watch-workers.sh" "$ISSUE" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# watch-workers が FIFO を開くのを待つ
sleep 0.5

# 即座に書き込み
echo '{"issue":99,"status":"merged","detail":"PR-99"}' > "${SESSION_IPC_DIR}/worker-${ISSUE}" &
WRITER_PID=$!

# 完了をポーリング（3秒以内に完了するはず）
WATCH_DONE=0
for _ in $(seq 1 30); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

kill "$WRITER_PID" 2>/dev/null || true
rm -f "${SESSION_IPC_DIR}/worker-${ISSUE}"
wait "$WRITER_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true

assert_eq "Completed before timeout" "1" "$WATCH_DONE"

RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Normal result contains merged" '"status":"merged"' "$RESULT"

report_results
