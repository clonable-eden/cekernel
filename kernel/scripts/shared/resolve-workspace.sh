#!/usr/bin/env bash
# resolve-workspace.sh — 現在の WezTerm workspace を解決するヘルパー
#
# Usage: source resolve-workspace.sh
#
# Functions:
#   resolve_workspace  — 現在の pane が属する workspace 名を返す（取得不可時は空文字）
#   build_workspace_args — workspace 名から wezterm cli spawn 用の引数を組み立てる

resolve_workspace() {
  # WEZTERM_PANE が未設定なら空文字（WezTerm 外での実行）
  if [[ -z "${WEZTERM_PANE:-}" ]]; then
    echo ""
    return 0
  fi

  # wezterm cli list から現在の pane の workspace を取得
  local json
  json=$(wezterm cli list --format json 2>/dev/null) || {
    echo ""
    return 0
  }

  local workspace
  workspace=$(echo "$json" | jq -r ".[] | select(.pane_id == ${WEZTERM_PANE}) | .workspace" 2>/dev/null) || {
    echo ""
    return 0
  }

  # jq が null や空文字を返した場合
  if [[ -z "$workspace" || "$workspace" == "null" ]]; then
    echo ""
    return 0
  fi

  echo "$workspace"
}

build_workspace_args() {
  local workspace="${1:-}"
  if [[ -n "$workspace" ]]; then
    echo "--workspace ${workspace}"
  else
    echo ""
  fi
}
