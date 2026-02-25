#!/usr/bin/env bash
# test-watch-workers.sh — セッションスコープ内の watch-workers テスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: watch-workers (session-scoped)"

export SESSION_ID="test-watch-00000001"
source "${KERNEL_DIR}/scripts/shared/session-id.sh"

ISSUES=(20 21)

cleanup() {
  for issue in "${ISSUES[@]}"; do
    rm -f "${SESSION_IPC_DIR}/worker-${issue}"
  done
  rmdir "$SESSION_IPC_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# セットアップ: セッションディレクトリに FIFO を作成
mkdir -p "$SESSION_IPC_DIR"
for issue in "${ISSUES[@]}"; do
  mkfifo "${SESSION_IPC_DIR}/worker-${issue}"
done

# ── Test: watch-workers.sh がセッションスコープの FIFO を並列監視 ──
RESULT_FILE=$(mktemp)

# バックグラウンドで watch-workers を起動
bash "${KERNEL_DIR}/scripts/orchestrator/watch-workers.sh" "${ISSUES[@]}" > "$RESULT_FILE" 2>/dev/null &
WATCH_PID=$!

# watch-workers が FIFO を開くのを待つ
sleep 0.5

# 各 FIFO に書き込み
WRITER_PIDS=()
for issue in "${ISSUES[@]}"; do
  bash -c "echo '{\"issue\":${issue},\"status\":\"merged\",\"detail\":\"PR-${issue}\"}' > '${SESSION_IPC_DIR}/worker-${issue}'" &
  WRITER_PIDS+=($!)
done

# watch-workers の完了をポーリング（最大 5 秒）
WATCH_DONE=0
for _ in $(seq 1 50); do
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    WATCH_DONE=1
    break
  fi
  sleep 0.1
done

# watch-workers 終了後、残存 writer を kill（RED フェーズでは reader がいないため block する）
for pid in "${WRITER_PIDS[@]}"; do
  kill "$pid" 2>/dev/null || true
done
# kill 後に FIFO を削除して open() をアンブロック
for issue in "${ISSUES[@]}"; do
  rm -f "${SESSION_IPC_DIR}/worker-${issue}"
done
for pid in "${WRITER_PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done
wait "$WATCH_PID" 2>/dev/null || true

if [[ "$WATCH_DONE" -eq 0 ]]; then
  rm -f "$RESULT_FILE"
  echo "  FAIL: watch-workers timed out (not reading session FIFOs)"
  ((TESTS_FAILED++)) || true
  report_results
  exit "$TESTS_FAILED"
fi

# 結果を検証
RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Issue 20 result received" '"issue":20' "$RESULT"
assert_match "Issue 21 result received" '"issue":21' "$RESULT"
assert_match "Issue 20 merged (not error)" '"status":"merged"' "$RESULT"

report_results
