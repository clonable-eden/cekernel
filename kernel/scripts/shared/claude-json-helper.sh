#!/usr/bin/env bash
# claude-json-helper.sh — ~/.claude.json の trust エントリを安全に読み書きするヘルパー
#
# Usage: source claude-json-helper.sh
#
# 関数:
#   acquire_claude_json_lock  — mkdir ベースのロック取得（最大10秒待機）
#   release_claude_json_lock  — ロック解放
#   register_trust <path>     — worktree パスの trust エントリを追加
#   unregister_trust <path>   — worktree パスの trust エントリを削除
#
# 環境変数（テスト用にオーバーライド可能）:
#   CLAUDE_JSON — ~/.claude.json のパス（デフォルト: ${HOME}/.claude.json）
#   LOCK_DIR    — ロックディレクトリ（デフォルト: ${CLAUDE_JSON}.lock）

CLAUDE_JSON="${CLAUDE_JSON:-${HOME}/.claude.json}"
LOCK_DIR="${LOCK_DIR:-${CLAUDE_JSON}.lock}"

acquire_claude_json_lock() {
  local max_wait=10
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ "$waited" -ge "$max_wait" ]]; then
      echo "Error: failed to acquire lock after ${max_wait}s" >&2
      return 1
    fi
    sleep 1
  done
}

release_claude_json_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

register_trust() {
  local worktree_path="$1"

  acquire_claude_json_lock || return 1
  trap 'release_claude_json_lock' RETURN

  # ファイルが存在しない場合は空の JSON を用意
  if [[ ! -f "$CLAUDE_JSON" ]]; then
    echo '{}' > "$CLAUDE_JSON"
  fi

  local tmp="${CLAUDE_JSON}.tmp.$$"
  jq --arg path "$worktree_path" '
    .projects[$path] = ((.projects[$path] // {}) + {
      hasTrustDialogAccepted: true,
      hasTrustDialogHooksAccepted: true,
      hasCompletedProjectOnboarding: true,
      hasClaudeMdExternalIncludesApproved: true,
      hasClaudeMdExternalIncludesWarningShown: true
    })
  ' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
}

unregister_trust() {
  local worktree_path="$1"

  # ファイルが存在しない場合は何もしない
  if [[ ! -f "$CLAUDE_JSON" ]]; then
    return 0
  fi

  acquire_claude_json_lock || return 1
  trap 'release_claude_json_lock' RETURN

  local tmp="${CLAUDE_JSON}.tmp.$$"
  jq --arg path "$worktree_path" '
    del(.projects[$path])
  ' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
}
