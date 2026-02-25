#!/usr/bin/env bash
# test-workspace-resolution.sh — spawn-worker.sh の workspace 解決ロジックのテスト
#
# WezTerm コマンドはモックし、workspace 解決ロジックの振る舞いを検証する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "test: workspace-resolution"

# ── テスト用セッション ──
export SESSION_ID="test-workspace-00000001"
source "${KERNEL_DIR}/scripts/session-id.sh"

# ── resolve_workspace 関数をロード ──
source "${KERNEL_DIR}/scripts/resolve-workspace.sh"

# ── Test 1: WEZTERM_PANE が未設定の場合、空文字を返す ──
unset WEZTERM_PANE 2>/dev/null || true
RESULT=$(resolve_workspace)
assert_eq "No WEZTERM_PANE: returns empty" "" "$RESULT"

# ── Test 2: WEZTERM_PANE が設定されている場合、対応する workspace を返す ──
export WEZTERM_PANE=5
# wezterm cli list のモック: JSON 出力を返す
wezterm() {
  if [[ "$1" == "cli" && "$2" == "list" ]]; then
    cat <<'MOCK_JSON'
[
  {"pane_id": 3, "workspace": "default"},
  {"pane_id": 5, "workspace": "orchestrator-ws"},
  {"pane_id": 7, "workspace": "other-ws"}
]
MOCK_JSON
  fi
}
export -f wezterm

RESULT=$(resolve_workspace)
assert_eq "WEZTERM_PANE=5: returns orchestrator-ws" "orchestrator-ws" "$RESULT"

# ── Test 3: WEZTERM_PANE が存在するが一致する pane がない場合、空文字を返す ──
export WEZTERM_PANE=999
RESULT=$(resolve_workspace)
assert_eq "WEZTERM_PANE=999 (no match): returns empty" "" "$RESULT"

# ── Test 4: wezterm コマンドが失敗した場合、空文字を返す ──
export WEZTERM_PANE=5
wezterm() {
  return 1
}
export -f wezterm

RESULT=$(resolve_workspace)
assert_eq "wezterm fails: returns empty" "" "$RESULT"

# ── Test 5: build_workspace_args が workspace ありの場合 --workspace を返す ──
ARGS=$(build_workspace_args "my-workspace")
assert_eq "build_workspace_args with workspace" "--workspace my-workspace" "$ARGS"

# ── Test 6: build_workspace_args が空文字の場合、空文字を返す ──
ARGS=$(build_workspace_args "")
assert_eq "build_workspace_args with empty workspace" "" "$ARGS"

# ── クリーンアップ ──
unset -f wezterm 2>/dev/null || true
rm -rf "$SESSION_IPC_DIR"

report_results
