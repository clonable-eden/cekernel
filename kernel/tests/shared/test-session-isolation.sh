#!/usr/bin/env bash
# test-session-isolation.sh — 異なるセッション間の FIFO 分離テスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: session-isolation"

ISSUE_NUMBER=10

# ── セッション A ──
SESSION_A="test-isolation-aaaaaaaa"
SESSION_A_DIR="/tmp/cekernel-ipc/${SESSION_A}"
mkdir -p "$SESSION_A_DIR"
FIFO_A="${SESSION_A_DIR}/worker-${ISSUE_NUMBER}"
mkfifo "$FIFO_A"

# ── セッション B（同じ issue 番号） ──
SESSION_B="test-isolation-bbbbbbbb"
SESSION_B_DIR="/tmp/cekernel-ipc/${SESSION_B}"
mkdir -p "$SESSION_B_DIR"
FIFO_B="${SESSION_B_DIR}/worker-${ISSUE_NUMBER}"
mkfifo "$FIFO_B"

# ── Test: 同じ issue 番号でも別セッションなら衝突しない ──
assert_fifo_exists "Session A FIFO exists" "$FIFO_A"
assert_fifo_exists "Session B FIFO exists" "$FIFO_B"
assert_eq "FIFOs are at different paths" "1" "$([[ "$FIFO_A" != "$FIFO_B" ]] && echo 1 || echo 0)"

# ── Test: 各セッションに独立してデータを書き込み・読み取り ──
RESULT_A=$(mktemp)
RESULT_B=$(mktemp)

(cat "$FIFO_A" > "$RESULT_A") &
PID_A=$!
(cat "$FIFO_B" > "$RESULT_B") &
PID_B=$!

echo '{"session":"A"}' > "$FIFO_A"
echo '{"session":"B"}' > "$FIFO_B"

wait "$PID_A" || true
wait "$PID_B" || true

assert_match "Session A received its own data" '"session":"A"' "$(cat "$RESULT_A")"
assert_match "Session B received its own data" '"session":"B"' "$(cat "$RESULT_B")"

# クリーンアップ
rm -f "$FIFO_A" "$FIFO_B" "$RESULT_A" "$RESULT_B"
rmdir "$SESSION_A_DIR" 2>/dev/null || true
rmdir "$SESSION_B_DIR" 2>/dev/null || true

report_results
