#!/usr/bin/env bash
# watch-workers.sh — 複数 Worker の完了を並列監視
#
# Usage: watch-workers.sh <issue-number> [issue-number...]
#
# Environment:
#   KERNEL_WORKER_TIMEOUT — Worker のタイムアウト秒数（デフォルト: 3600）
#
# 各 Worker の FIFO をバックグラウンドで並列監視し、
# 全 Worker の完了を待つ。結果を標準出力に JSON Lines で出力する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/session-id.sh"

ISSUE_NUMBERS=("$@")
[[ ${#ISSUE_NUMBERS[@]} -gt 0 ]] || { echo "Usage: watch-workers.sh <issue-number> [...]" >&2; exit 1; }

FIFO_DIR="$SESSION_IPC_DIR"
RESULT_DIR=$(mktemp -d)
PIDS=()
TIMEOUT="${KERNEL_WORKER_TIMEOUT:-3600}"

# 各 FIFO を並列監視
watch_one() {
  local issue="$1"
  local fifo="${FIFO_DIR}/worker-${issue}"

  if [[ ! -p "$fifo" ]]; then
    echo "{\"issue\":${issue},\"status\":\"error\",\"detail\":\"FIFO not found\"}" > "${RESULT_DIR}/${issue}"
    return 1
  fi

  echo "Watching issue #${issue} (timeout: ${TIMEOUT}s)..." >&2

  # FIFO を read-write で開いて open() のブロッキングを回避（SIGALRM 相当）
  local result
  exec 3<>"$fifo"
  if read -t "$TIMEOUT" result <&3; then
    exec 3>&-
    echo "$result" > "${RESULT_DIR}/${issue}"
    rm -f "$fifo"
    echo "Issue #${issue} completed." >&2
  else
    exec 3>&-
    echo "{\"issue\":${issue},\"status\":\"timeout\",\"detail\":\"No response within ${TIMEOUT}s\"}" > "${RESULT_DIR}/${issue}"
    rm -f "$fifo"
    echo "Issue #${issue} timed out after ${TIMEOUT}s." >&2
    return 1
  fi
}

for issue in "${ISSUE_NUMBERS[@]}"; do
  watch_one "$issue" &
  PIDS+=($!)
done

echo "Watching ${#ISSUE_NUMBERS[@]} workers (timeout: ${TIMEOUT}s)..." >&2

# 全バックグラウンドプロセスの完了を待機
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED=$((FAILED + 1))
done

# 結果を出力
echo "---" >&2
echo "All workers finished. (failed: ${FAILED})" >&2
echo "---" >&2

for issue in "${ISSUE_NUMBERS[@]}"; do
  if [[ -f "${RESULT_DIR}/${issue}" ]]; then
    cat "${RESULT_DIR}/${issue}"
  fi
done

# クリーンアップ
rm -rf "$RESULT_DIR"

exit "$FAILED"
