#!/usr/bin/env bash
# test-concurrency-guard.sh — spawn-worker.sh の concurrency guard テスト
#
# spawn-worker.sh 全体は WezTerm 依存のため直接実行できない。
# ここでは concurrency guard ロジックを抽出してテストする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: concurrency-guard"

# テスト用セッション
export CEKERNEL_SESSION_ID="test-concurrency-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── セットアップ: クリーンな状態を保証 ──
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

# active_worker_count 関数を再定義（spawn-worker.sh からの抽出）
active_worker_count() {
  find "$CEKERNEL_IPC_DIR" -maxdepth 1 -name 'worker-*' -type p 2>/dev/null | wc -l | tr -d ' '
}

# ── Test 1: Worker 0 体でカウントが 0 ──
COUNT=$(active_worker_count)
assert_eq "No workers: count is 0" "0" "$COUNT"

# ── Test 2: FIFO を 1 つ作成 → カウント 1 ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-10"
COUNT=$(active_worker_count)
assert_eq "One worker FIFO: count is 1" "1" "$COUNT"

# ── Test 3: FIFO を 3 つまで増やす → カウント 3 ──
mkfifo "${CEKERNEL_IPC_DIR}/worker-11"
mkfifo "${CEKERNEL_IPC_DIR}/worker-12"
COUNT=$(active_worker_count)
assert_eq "Three worker FIFOs: count is 3" "3" "$COUNT"

# ── Test 4: MAX_WORKERS=3 で 3 体の場合、ガードが発動する ──
# spawn-worker.sh の該当ロジックをインラインで検証
MAX_WORKERS=3
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_WORKERS" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard triggers at MAX_WORKERS=3 with 3 active" "yes" "$GUARD_TRIGGERED"

# ── Test 5: FIFO を 1 つ削除 → ガード解除 ──
rm -f "${CEKERNEL_IPC_DIR}/worker-12"
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_WORKERS" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard released after removing one FIFO" "no" "$GUARD_TRIGGERED"

# ── Test 6: MAX_WORKERS=5 で 2 体 → ガード未発動 ──
MAX_WORKERS=5
ACTIVE=$(active_worker_count)
if [[ "$ACTIVE" -ge "$MAX_WORKERS" ]]; then
  GUARD_TRIGGERED="yes"
else
  GUARD_TRIGGERED="no"
fi
assert_eq "Guard not triggered: 2 active < MAX_WORKERS=5" "no" "$GUARD_TRIGGERED"

# ── Test 7: 通常ファイル (非 FIFO) はカウントされない ──
touch "${CEKERNEL_IPC_DIR}/worker-99"
COUNT=$(active_worker_count)
assert_eq "Regular file not counted as worker" "2" "$COUNT"

# ── クリーンアップ ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
