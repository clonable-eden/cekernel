#!/usr/bin/env bash
# watch-workers.sh — Monitor multiple Worker completions in parallel
#
# Usage: watch-workers.sh <issue-number> [issue-number...]
#
# Environment:
#   CEKERNEL_WORKER_TIMEOUT — Worker timeout in seconds (default: 3600)
#
# Monitors each Worker's FIFO in background, waits for all Workers to complete.
# Outputs results to stdout as JSON Lines.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"

ISSUE_NUMBERS=("$@")
[[ ${#ISSUE_NUMBERS[@]} -gt 0 ]] || { echo "Usage: watch-workers.sh <issue-number> [...]" >&2; exit 1; }

FIFO_DIR="$CEKERNEL_IPC_DIR"
RESULT_DIR=$(mktemp -d)
PIDS=()
TIMEOUT="${CEKERNEL_WORKER_TIMEOUT:-3600}"

# Monitor each FIFO in parallel
watch_one() {
  local issue="$1"
  local fifo="${FIFO_DIR}/worker-${issue}"

  if [[ ! -p "$fifo" ]]; then
    echo "{\"issue\":${issue},\"status\":\"error\",\"detail\":\"FIFO not found\"}" > "${RESULT_DIR}/${issue}"
    return 1
  fi

  echo "Watching issue #${issue} (timeout: ${TIMEOUT}s)..." >&2

  # Open FIFO read-write to avoid blocking on open() (SIGALRM equivalent)
  local result
  exec 3<>"$fifo"
  if read -r -t "$TIMEOUT" result <&3; then
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

# Wait for all background processes to complete
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED=$((FAILED + 1))
done

# Output results
echo "---" >&2
echo "All workers finished. (failed: ${FAILED})" >&2
echo "---" >&2

for issue in "${ISSUE_NUMBERS[@]}"; do
  if [[ -f "${RESULT_DIR}/${issue}" ]]; then
    cat "${RESULT_DIR}/${issue}"
  fi
done

# Cleanup
rm -rf "$RESULT_DIR"

exit "$FAILED"
