#!/usr/bin/env bash
# test-ipc-lifecycle.sh — セッションスコープ付き IPC ライフサイクルテスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: ipc-lifecycle (session-scoped)"

# テスト用セッション
export CEKERNEL_SESSION_ID="test-lifecycle-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# セットアップ: セッションディレクトリと FIFO を作成
ISSUE_NUMBER=42
mkdir -p "$CEKERNEL_IPC_DIR"
FIFO="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}"
mkfifo "$FIFO"

assert_fifo_exists "FIFO created in session dir" "$FIFO"

# ── Test: notify-complete.sh 経由で書き込み → 読み取り → JSON 検証 ──
# バックグラウンドで読み取り
RESULT_FILE=$(mktemp)
(cat "$FIFO" > "$RESULT_FILE") &
READER_PID=$!

# notify-complete.sh で書き込み
bash "${CEKERNEL_DIR}/scripts/worker/notify-complete.sh" "$ISSUE_NUMBER" merged 99

# 読み取り完了を待機
wait "$READER_PID" || true

# JSON の検証
RESULT=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"

assert_match "Result contains issue number" '"issue":42' "$RESULT"
assert_match "Result contains status" '"status":"merged"' "$RESULT"
assert_match "Result contains detail" '"detail":"99"' "$RESULT"
assert_match "Result contains timestamp" '"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$RESULT"

# クリーンアップ
rm -f "$FIFO"
rmdir "$CEKERNEL_IPC_DIR" 2>/dev/null || true

report_results
