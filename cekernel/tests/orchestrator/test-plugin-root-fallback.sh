#!/usr/bin/env bash
# test-plugin-root-fallback.sh — CLAUDE_PLUGIN_ROOT フォールバックのテスト
#
# spawn-worker.sh が直接実行されたとき、CLAUDE_PLUGIN_ROOT が
# SCRIPT_DIR/.. から自動導出されることを検証する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${CEKERNEL_DIR}/scripts/orchestrator"

echo "test: plugin-root-fallback"

# ── Test 1: CLAUDE_PLUGIN_ROOT 未設定時にフォールバックが効く ──
# サブシェルで CLAUDE_PLUGIN_ROOT を unset して spawn-worker.sh の冒頭ロジックを検証
RESULT=$(
  unset CLAUDE_PLUGIN_ROOT
  # spawn-worker.sh の冒頭を再現: SCRIPT_DIR → CLAUDE_PLUGIN_ROOT フォールバック
  SCRIPT_DIR_LOCAL="$SCRIPTS_DIR"
  # source ではなく、spawn-worker.sh の該当行のロジックを抽出して実行
  bash -c "
    set -euo pipefail
    SCRIPT_DIR='${SCRIPTS_DIR}'
    source \"\${SCRIPT_DIR}/../shared/session-id.sh\"
    # この行が spawn-worker.sh に存在するかテスト
    CLAUDE_PLUGIN_ROOT=\"\${CLAUDE_PLUGIN_ROOT:-\$(cd \"\${SCRIPT_DIR}/../..\" && pwd)}\"
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  "
)
assert_eq "Fallback derives CLAUDE_PLUGIN_ROOT from SCRIPT_DIR/../.." "$CEKERNEL_DIR" "$RESULT"

# ── Test 2: CLAUDE_PLUGIN_ROOT が既に設定されていれば上書きしない ──
RESULT=$(
  export CLAUDE_PLUGIN_ROOT="/custom/plugin/root"
  bash -c "
    set -euo pipefail
    SCRIPT_DIR='${SCRIPTS_DIR}'
    source \"\${SCRIPT_DIR}/../shared/session-id.sh\"
    CLAUDE_PLUGIN_ROOT=\"\${CLAUDE_PLUGIN_ROOT:-\$(cd \"\${SCRIPT_DIR}/../..\" && pwd)}\"
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  "
)
assert_eq "Existing CLAUDE_PLUGIN_ROOT is preserved" "/custom/plugin/root" "$RESULT"

# ── Test 3: spawn-worker.sh 自体が CLAUDE_PLUGIN_ROOT フォールバック行を含む ──
# spawn-worker.sh のソースに実際にフォールバック行が存在するかを確認
SPAWN_SCRIPT="${SCRIPTS_DIR}/spawn-worker.sh"
if grep -q 'CLAUDE_PLUGIN_ROOT=.*CLAUDE_PLUGIN_ROOT:-' "$SPAWN_SCRIPT"; then
  FOUND="yes"
else
  FOUND="no"
fi
assert_eq "spawn-worker.sh contains CLAUDE_PLUGIN_ROOT fallback" "yes" "$FOUND"

report_results
