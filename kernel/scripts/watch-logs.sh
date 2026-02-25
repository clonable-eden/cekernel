#!/usr/bin/env bash
# watch-logs.sh — Worker ログのリアルタイム監視
#
# Usage: watch-logs.sh [issue-number]
#   引数なし: 全 Worker のログを監視
#   引数あり: 指定 Worker のログのみ監視
#
# OS analogy: tail -f / journalctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/session-id.sh"

LOG_DIR="${SESSION_IPC_DIR}/logs"

if [[ ! -d "$LOG_DIR" ]]; then
  echo "No log directory found at ${LOG_DIR}" >&2
  echo "Workers may not have been spawned yet." >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  ISSUE_NUMBER="$1"
  LOG_FILE="${LOG_DIR}/worker-${ISSUE_NUMBER}.log"
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "No log file for issue #${ISSUE_NUMBER}" >&2
    exit 1
  fi
  echo "Watching worker #${ISSUE_NUMBER} logs..." >&2
  tail -f "$LOG_FILE"
else
  # 全ワーカーのログを監視
  LOG_FILES=("${LOG_DIR}"/worker-*.log)
  if [[ ! -f "${LOG_FILES[0]}" ]]; then
    echo "No worker log files found in ${LOG_DIR}" >&2
    exit 1
  fi
  echo "Watching all worker logs..." >&2
  tail -f "${LOG_FILES[@]}"
fi
