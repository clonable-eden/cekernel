#!/usr/bin/env bash
# watch-worker.sh — Monitor Worker completion via FIFO + state file fallback
#
# Usage: watch-worker.sh <issue-number> [issue-number...]
#
# Environment:
#   CEKERNEL_WORKER_TIMEOUT — Worker timeout in seconds (default: 3600)
#   CEKERNEL_POLL_INTERVAL  — State file poll interval in seconds (default: 30)
#
# Monitors each Worker via triple-path detection:
#   1. FIFO (primary, sub-second latency)
#   2. State file polling (fallback, up to POLL_INTERVAL latency)
#   3. Process crash detection (backend_worker_alive check)
# Outputs results to stdout as JSON Lines.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/backend-adapter.sh"

ISSUE_NUMBERS=("$@")
[[ ${#ISSUE_NUMBERS[@]} -gt 0 ]] || { echo "Usage: watch-worker.sh <issue-number> [...]" >&2; exit 1; }

FIFO_DIR="$CEKERNEL_IPC_DIR"
RESULT_DIR=$(mktemp -d)
PIDS=()
TIMEOUT="${CEKERNEL_WORKER_TIMEOUT:-3600}"
POLL_INTERVAL="${CEKERNEL_POLL_INTERVAL:-30}"

# ── Helper: build result JSON from state file (fallback path) ──
build_result_from_state() {
  local state_json="$1"
  echo "$state_json" | jq -c \
    '{issue: .issue, status: .detail, detail: "detected-via-state-fallback", timestamp: .timestamp}'
}

# ── Helper: log to worker log file ──
log_event() {
  local issue="$1" event="$2" detail="$3"
  local log_file="${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log"
  if [[ -d "${CEKERNEL_IPC_DIR}/logs" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${event} ${detail}" >> "$log_file"
  fi
}

# Monitor each Worker in parallel
watch_one() {
  local issue="$1"
  local fifo="${FIFO_DIR}/worker-${issue}"
  local has_fifo=1
  local result=""
  local elapsed=0

  log_event "$issue" "FIFO_WATCH_START" "issue=#${issue} timeout=${TIMEOUT} poll_interval=${POLL_INTERVAL}"

  # If FIFO exists, open it. If not, fall through to state-only polling.
  if [[ -p "$fifo" ]]; then
    exec 3<>"$fifo"
    echo "Watching issue #${issue} (timeout: ${TIMEOUT}s, poll: ${POLL_INTERVAL}s)..." >&2
  else
    has_fifo=0
    echo "Warning: FIFO not found for issue #${issue}. Falling back to state file polling." >&2
    log_event "$issue" "FIFO_MISSING" "issue=#${issue} path=${fifo}"
  fi

  while [[ $elapsed -lt $TIMEOUT ]]; do
    # Clamp wait time to remaining budget
    local remaining=$((TIMEOUT - elapsed))
    local wait_time=$POLL_INTERVAL
    [[ $remaining -lt $wait_time ]] && wait_time=$remaining

    # Primary: FIFO read (only if FIFO was available)
    if [[ $has_fifo -eq 1 ]]; then
      if read -r -t "$wait_time" result <&3; then
        exec 3>&-
        rm -f "$fifo"
        log_event "$issue" "FIFO_READ" "issue=#${issue}"
        echo "Issue #${issue} completed." >&2
        break
      fi
    else
      sleep "$wait_time"
    fi

    # Fallback: check state file
    local state_json
    state_json=$(worker_state_read "$issue")
    local state
    state=$(echo "$state_json" | jq -r '.state')
    if [[ "$state" == "TERMINATED" ]]; then
      result=$(build_result_from_state "$state_json")
      echo "Warning: issue #${issue} completed but FIFO notification was not received. Detected via state file." >&2
      log_event "$issue" "STATE_FALLBACK" "issue=#${issue} state=TERMINATED"
      [[ $has_fifo -eq 1 ]] && exec 3>&-
      rm -f "$fifo"
      break
    fi

    # Crash detection: if handle file exists but Worker process is dead, it crashed
    # Only check when handle file is present (without it, we can't verify process status)
    if [[ -f "${CEKERNEL_IPC_DIR}/handle-${issue}" ]] && ! backend_worker_alive "$issue" 2>/dev/null; then
      result="{\"issue\":${issue},\"status\":\"crashed\",\"detail\":\"Worker process died without completing\"}"
      echo "Error: issue #${issue} Worker process crashed (state: ${state})." >&2
      log_event "$issue" "WORKER_CRASH" "issue=#${issue} state=${state}"
      [[ $has_fifo -eq 1 ]] && exec 3>&-
      rm -f "$fifo"
      break
    fi

    elapsed=$((elapsed + wait_time))
  done

  # Timeout: neither FIFO nor state file indicated completion
  if [[ -z "$result" ]]; then
    [[ $has_fifo -eq 1 ]] && exec 3>&-
    rm -f "$fifo"
    result="{\"issue\":${issue},\"status\":\"timeout\",\"detail\":\"No response within ${TIMEOUT}s\"}"
    echo "Issue #${issue} timed out after ${TIMEOUT}s." >&2
    log_event "$issue" "WATCH_TIMEOUT" "issue=#${issue} timeout=${TIMEOUT}s"
  fi

  echo "$result" > "${RESULT_DIR}/${issue}"
  local result_status
  result_status=$(echo "$result" | jq -r '.status')
  [[ "$result_status" != "timeout" && "$result_status" != "error" && "$result_status" != "crashed" ]]
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
