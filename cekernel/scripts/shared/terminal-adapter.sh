#!/usr/bin/env bash
# terminal-adapter.sh — ターミナルマルチプレクサの抽象化レイヤー
#
# Usage: source terminal-adapter.sh
#
# WezTerm 固有の操作を関数でラップし、他スクリプトからの直接依存を排除する。
# 将来 tmux 等に対応する場合はこのファイルのみ差し替える（Rule of Separation）。
#
# Functions:
#   terminal_available          — ターミナルが利用可能か確認
#   terminal_resolve_workspace  — 現在の pane が属する workspace 名を返す
#   terminal_spawn_window       — 新しいウィンドウを作成し pane ID を返す
#   terminal_run_command        — 指定 pane でコマンドを実行
#   terminal_split_pane         — pane を分割（オプションでコマンド実行）
#   terminal_kill_pane          — pane を削除
#   terminal_kill_window        — pane が属するウィンドウの全ペインを削除
#   terminal_pane_alive         — pane が生きているか確認

terminal_available() {
  command -v wezterm >/dev/null 2>&1
}

terminal_resolve_workspace() {
  if [[ -z "${WEZTERM_PANE:-}" ]]; then
    echo ""
    return 0
  fi

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

  if [[ -z "$workspace" || "$workspace" == "null" ]]; then
    echo ""
    return 0
  fi

  echo "$workspace"
}

# terminal_spawn_window <cwd> [workspace]
# stdout: pane ID
terminal_spawn_window() {
  local cwd="$1"
  local workspace="${2:-}"
  local args=(--new-window --cwd "$cwd")
  if [[ -n "$workspace" ]]; then
    args+=(--workspace "$workspace")
  fi
  wezterm cli spawn "${args[@]}"
}

# terminal_run_command <pane-id> <command>
terminal_run_command() {
  local pane_id="$1"
  local cmd="$2"
  wezterm cli send-text --pane-id "$pane_id" -- "$cmd"
  wezterm cli send-text --pane-id "$pane_id" --no-paste $'\r'
}

# terminal_split_pane <direction> <percent> <pane-id> <cwd> [command...]
# direction: bottom | right
terminal_split_pane() {
  local direction="$1"
  local percent="$2"
  local pane_id="$3"
  local cwd="$4"
  shift 4
  local args=(
    "--${direction}" --percent "$percent"
    --pane-id "$pane_id"
    --cwd "$cwd"
  )
  if [[ $# -gt 0 ]]; then
    args+=(-- "$@")
  fi
  wezterm cli split-pane "${args[@]}"
}

# terminal_kill_pane <pane-id>
terminal_kill_pane() {
  local pane_id="$1"
  wezterm cli kill-pane --pane-id "$pane_id" 2>/dev/null || true
}

# terminal_kill_window <pane-id>
# pane が属するウィンドウの全ペインを kill。取得失敗時は指定 pane のみ kill。
terminal_kill_window() {
  local pane_id="$1"
  local window_panes
  window_panes=$(wezterm cli list --format json 2>/dev/null \
    | jq -r --argjson target "$pane_id" '
        (map(select(.pane_id == $target)) | first | .window_id) as $win
        | map(select(.window_id == $win)) | .[].pane_id
      ' 2>/dev/null) || true

  if [[ -n "$window_panes" ]]; then
    while IFS= read -r pane; do
      wezterm cli kill-pane --pane-id "$pane" 2>/dev/null || true
    done <<< "$window_panes"
    echo "Killed window panes for pane: ${pane_id}" >&2
  else
    wezterm cli kill-pane --pane-id "$pane_id" 2>/dev/null && \
      echo "Killed pane: ${pane_id}" >&2 || true
  fi
}

# terminal_pane_alive <pane-id>
# exit 0 if alive, exit 1 if dead
terminal_pane_alive() {
  local pane_id="$1"
  wezterm cli list --format json 2>/dev/null | grep -q "\"pane_id\":${pane_id}[,}]"
}
