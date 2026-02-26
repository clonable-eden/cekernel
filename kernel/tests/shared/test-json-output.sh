#!/usr/bin/env bash
# test-json-output.sh — JSON 出力のエスケープ安全性テスト
#
# 各スクリプトが生成する JSON が、特殊文字を含む場合でも
# 有効な JSON であることを検証する（Rule of Robustness）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: json-output"

# ── テスト用セッション ──
export CEKERNEL_SESSION_ID="test-json-output-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
mkdir -p "$CEKERNEL_IPC_DIR/logs"

# ── wezterm モック（health-check 用） ──
wezterm() { return 1; }
export -f wezterm

# ── gh モック（不要だが安全のため） ──
gh() { return 1; }
export -f gh

# ── Test 1: notify-complete.sh — DETAIL にダブルクォートを含む ──
FIFO="${CEKERNEL_IPC_DIR}/worker-901"
mkfifo "$FIFO"
# FIFO を読み取るバックグラウンドプロセス
RESULT_FILE=$(mktemp)
(exec 3<>"$FIFO"; read -r -t 5 result <&3; exec 3>&-; echo "$result" > "$RESULT_FILE") &
READER_PID=$!
sleep 0.1

bash "${CEKERNEL_DIR}/scripts/worker/notify-complete.sh" 901 failed 'CI failed "3 times"' 2>/dev/null
wait "$READER_PID" 2>/dev/null || true

RESULT=$(cat "$RESULT_FILE")
# jq で有効な JSON か検証
if echo "$RESULT" | jq . >/dev/null 2>&1; then
  echo "  PASS: notify-complete with quotes produces valid JSON"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: notify-complete with quotes produces invalid JSON"
  echo "    output: $RESULT"
  ((TESTS_FAILED++)) || true
fi
# 値が正しくエスケープされているか
DETAIL_VALUE=$(echo "$RESULT" | jq -r '.detail' 2>/dev/null || echo "")
assert_eq "notify-complete detail value preserved" 'CI failed "3 times"' "$DETAIL_VALUE"
rm -f "$RESULT_FILE" "$FIFO"

# ── Test 2: notify-complete.sh — DETAIL にバックスラッシュを含む ──
FIFO="${CEKERNEL_IPC_DIR}/worker-902"
mkfifo "$FIFO"
RESULT_FILE=$(mktemp)
(exec 3<>"$FIFO"; read -r -t 5 result <&3; exec 3>&-; echo "$result" > "$RESULT_FILE") &
READER_PID=$!
sleep 0.1

bash "${CEKERNEL_DIR}/scripts/worker/notify-complete.sh" 902 failed 'path\to\file' 2>/dev/null
wait "$READER_PID" 2>/dev/null || true

RESULT=$(cat "$RESULT_FILE")
if echo "$RESULT" | jq . >/dev/null 2>&1; then
  echo "  PASS: notify-complete with backslash produces valid JSON"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: notify-complete with backslash produces invalid JSON"
  echo "    output: $RESULT"
  ((TESTS_FAILED++)) || true
fi
rm -f "$RESULT_FILE" "$FIFO"

# ── Test 3: health-check.sh — ゾンビ worker の JSON 出力が有効 ──
# FIFO を作成して pane ファイルなし（ゾンビ判定される）
FIFO="${CEKERNEL_IPC_DIR}/worker-903"
mkfifo "$FIFO"
# git worktree は見つからないのでフォールバック（"No worktree found"）
RESULT=$(bash "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 903 2>/dev/null || true)
if echo "$RESULT" | head -1 | jq . >/dev/null 2>&1; then
  echo "  PASS: health-check produces valid JSON"
  ((TESTS_PASSED++)) || true
else
  echo "  FAIL: health-check produces invalid JSON"
  echo "    output: $RESULT"
  ((TESTS_FAILED++)) || true
fi
rm -f "$FIFO"

# ── Test 4: worker-status.sh — JSON Lines 出力が有効 ──
FIFO="${CEKERNEL_IPC_DIR}/worker-904"
mkfifo "$FIFO"
RESULT=$(bash "${CEKERNEL_DIR}/scripts/orchestrator/worker-status.sh" 2>/dev/null)
if [[ -n "$RESULT" ]]; then
  if echo "$RESULT" | head -1 | jq . >/dev/null 2>&1; then
    echo "  PASS: worker-status produces valid JSON"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: worker-status produces invalid JSON"
    echo "    output: $RESULT"
    ((TESTS_FAILED++)) || true
  fi
else
  echo "  FAIL: worker-status produced no output"
  ((TESTS_FAILED++)) || true
fi
rm -f "$FIFO"

# ── クリーンアップ ──
unset -f wezterm 2>/dev/null || true
unset -f gh 2>/dev/null || true
rm -rf "$CEKERNEL_IPC_DIR"

report_results
