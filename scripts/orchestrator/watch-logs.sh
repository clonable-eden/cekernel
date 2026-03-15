#!/usr/bin/env bash
# watch-logs.sh — Real-time monitoring of Worker logs
#
# Usage: watch-logs.sh [issue-number]
#   No argument: monitor all Worker logs
#   With argument: monitor specified Worker's log only
#
# OS analogy: tail -f / journalctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"

LOG_DIR="${CEKERNEL_IPC_DIR}/logs"

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
  # Monitor all worker logs
  LOG_FILES=("${LOG_DIR}"/worker-*.log)
  if [[ ! -f "${LOG_FILES[0]}" ]]; then
    echo "No worker log files found in ${LOG_DIR}" >&2
    exit 1
  fi
  echo "Watching all worker logs..." >&2
  tail -f "${LOG_FILES[@]}"
fi
