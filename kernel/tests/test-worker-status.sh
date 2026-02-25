#!/usr/bin/env bash
# test-worker-status.sh — worker-status.sh のテスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATUS_SCRIPT="${KERNEL_DIR}/scripts/worker-status.sh"

echo "test: worker-status"

# テスト用セッション
export SESSION_ID="test-wstatus-00000001"
source "${KERNEL_DIR}/scripts/session-id.sh"

# ── セットアップ ──
rm -rf "$SESSION_IPC_DIR"
mkdir -p "$SESSION_IPC_DIR"

# ── Test 1: Worker なしの場合、出力が空 ──
OUTPUT=$(bash "$STATUS_SCRIPT")
assert_eq "No workers: empty output" "" "$OUTPUT"

# ── Test 2: FIFO 作成後に 1 行出力される ──
mkfifo "${SESSION_IPC_DIR}/worker-20"
OUTPUT=$(bash "$STATUS_SCRIPT")
LINE_COUNT=$(echo "$OUTPUT" | grep -c 'issue' || true)
assert_eq "One worker: one JSON line" "1" "$LINE_COUNT"

# ── Test 3: issue 番号が正しく含まれる ──
assert_match "Output contains issue 20" '"issue":20' "$OUTPUT"

# ── Test 4: FIFO パスが含まれる ──
assert_match "Output contains FIFO path" "worker-20" "$OUTPUT"

# ── Test 5: 複数 Worker で複数行出力 ──
mkfifo "${SESSION_IPC_DIR}/worker-21"
mkfifo "${SESSION_IPC_DIR}/worker-22"
OUTPUT=$(bash "$STATUS_SCRIPT")
LINE_COUNT=$(echo "$OUTPUT" | grep -c 'issue')
assert_eq "Three workers: three JSON lines" "3" "$LINE_COUNT"

# ── Test 6: uptime フィールドが含まれる ──
assert_match "Output contains uptime field" '"uptime":' "$OUTPUT"

# ── Test 7: セッションディレクトリが存在しない場合 exit 1 ──
rm -rf "$SESSION_IPC_DIR"
export SESSION_ID="test-wstatus-nonexistent"
export SESSION_IPC_DIR="/tmp/glimmer-ipc/${SESSION_ID}"
EXIT_CODE=0
bash "$STATUS_SCRIPT" 2>/dev/null || EXIT_CODE=$?
assert_eq "Missing session dir: exit 1" "1" "$EXIT_CODE"

# ── クリーンアップ ──
export SESSION_ID="test-wstatus-00000001"
export SESSION_IPC_DIR="/tmp/glimmer-ipc/${SESSION_ID}"
rm -rf "$SESSION_IPC_DIR"

report_results
