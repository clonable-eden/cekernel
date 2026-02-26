#!/usr/bin/env bash
# session-id.sh — セッション ID の生成と IPC ディレクトリの導出
#
# Usage: source session-id.sh
#
# 環境変数:
#   CEKERNEL_SESSION_ID — 未設定なら {repo-name}-{random-hex-8} を自動生成
#   CEKERNEL_IPC_DIR    — /tmp/cekernel-ipc/${CEKERNEL_SESSION_ID} を export

if [[ -z "${CEKERNEL_SESSION_ID:-}" ]]; then
  # リポジトリ名を取得（git 外なら "glimmer" をフォールバック）
  _repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "glimmer")
  # ランダム 8 桁 hex
  _hex=$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
  export CEKERNEL_SESSION_ID="${_repo_name}-${_hex}"
  unset _repo_name _hex
fi

export CEKERNEL_IPC_DIR="/tmp/cekernel-ipc/${CEKERNEL_SESSION_ID}"
