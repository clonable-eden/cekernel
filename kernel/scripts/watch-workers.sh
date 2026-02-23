#!/usr/bin/env bash
# watch-workers.sh — 複数 Worker の完了を並列監視
#
# Usage: watch-workers.sh <issue-number> [issue-number...]
#
# 各 Worker の FIFO をバックグラウンドで並列監視し、
# 全 Worker の完了を待つ。結果を標準出力に JSON Lines で出力する。
set -euo pipefail

ISSUE_NUMBERS=("$@")
[[ ${#ISSUE_NUMBERS[@]} -gt 0 ]] || { echo "Usage: watch-workers.sh <issue-number> [...]" >&2; exit 1; }

FIFO_DIR="/tmp/glimmer-ipc"
RESULT_DIR=$(mktemp -d)
PIDS=()

# 各 FIFO を並列監視
watch_one() {
  local issue="$1"
  local fifo="${FIFO_DIR}/worker-${issue}"

  if [[ ! -p "$fifo" ]]; then
    echo "{\"issue\":${issue},\"status\":\"error\",\"detail\":\"FIFO not found\"}" > "${RESULT_DIR}/${issue}"
    return 1
  fi

  echo "Watching issue #${issue}..." >&2

  # ブロッキング読み取り — Worker が書き込むまで待機
  local result
  result=$(cat "$fifo")
  echo "$result" > "${RESULT_DIR}/${issue}"

  # FIFO を即座にクリーンアップ
  rm -f "$fifo"

  echo "Issue #${issue} completed." >&2
}

for issue in "${ISSUE_NUMBERS[@]}"; do
  watch_one "$issue" &
  PIDS+=($!)
done

echo "Watching ${#ISSUE_NUMBERS[@]} workers..." >&2

# 全バックグラウンドプロセスの完了を待機
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || ((FAILED++))
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
