#!/usr/bin/env bash
# watch.sh — Monitor process completion via state file polling + backend verdict
#
# Usage: watch.sh <issue-number> [issue-number...]
#
# Environment:
#   CEKERNEL_WORKER_TIMEOUT — Process timeout in seconds (default: 3600)
#   CEKERNEL_STATE_POLL_INTERVAL — State file poll interval in seconds (default: 5)
#   CEKERNEL_POLL_INTERVAL  — Backend verdict poll interval in seconds (default: 30)
#   CEKERNEL_WATCH_QUERY_RETRY_MAX — Consecutive unverifiable polls
#     (query-failed / unknown-value) tolerated before escalating an
#     "error" result (default: 3; ADR-0018 degradation policy)
#
# Monitors each process via dual-path detection:
#   1. State file polling (primary, up to STATE_POLL_INTERVAL latency)
#   2. Process crash detection (backend verdict, ADR-0018);
#      blocked sessions (permission-dialog stall) are surfaced as a
#      distinct "blocked" result (ADR-0016)
# Outputs results to stdout as JSON Lines.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/session-id.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/backend-adapter.sh"

ISSUE_NUMBERS=("$@")
[[ ${#ISSUE_NUMBERS[@]} -gt 0 ]] || { echo "Usage: watch.sh <issue-number> [...]" >&2; exit 1; }

RESULT_DIR=$(mktemp -d)
PIDS=()
TIMEOUT="${CEKERNEL_WORKER_TIMEOUT:-3600}"
STATE_POLL_INTERVAL="${CEKERNEL_STATE_POLL_INTERVAL:-5}"
POLL_INTERVAL="${CEKERNEL_POLL_INTERVAL:-30}"
QUERY_RETRY_MAX="${CEKERNEL_WATCH_QUERY_RETRY_MAX:-3}"

# ── Helper: build result JSON from state file ──
# ADR-0020 Phase 1a: state detail carries "result:detail" (detail may contain
# colons, so split on the first colon only). Old format (no colon) is backward
# compatible: result = whole string, detail = "".
build_result_from_state() {
  local state_json="$1"
  echo "$state_json" | jq -c \
    '{issue: .issue, result: (.detail | split(":")[0]), detail: (.detail | split(":")[1:] | join(":")), timestamp: .timestamp}'
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
  local result=""
  local elapsed=0
  local query_failures=0

  log_event "$issue" "WATCH_START" "issue=#${issue} timeout=${TIMEOUT} state_poll=${STATE_POLL_INTERVAL} backend_poll=${POLL_INTERVAL}"

  echo "Watching issue #${issue} (timeout: ${TIMEOUT}s, state_poll: ${STATE_POLL_INTERVAL}s, backend_poll: ${POLL_INTERVAL}s)..." >&2

  # ADR-0020 Phase 1: polling split — state at STATE_POLL_INTERVAL (5s),
  # backend verdict at POLL_INTERVAL (30s). Track when the next backend
  # check is due.
  local next_backend_check=$POLL_INTERVAL

  while [[ $elapsed -lt $TIMEOUT ]]; do
    # Clamp wait time to remaining budget
    local remaining=$((TIMEOUT - elapsed))
    local wait_time=$STATE_POLL_INTERVAL
    [[ $remaining -lt $wait_time ]] && wait_time=$remaining

    sleep "$wait_time"

    elapsed=$((elapsed + wait_time))

    # Primary: check state file (every STATE_POLL_INTERVAL)
    local state_json
    state_json=$(worker_state_read "$issue")
    local state
    state=$(echo "$state_json" | jq -r '.state')
    if [[ "$state" == "TERMINATED" ]]; then
      result=$(build_result_from_state "$state_json")
      echo "Issue #${issue} completed (detected via state file)." >&2
      log_event "$issue" "STATE_COMPLETE" "issue=#${issue} state=TERMINATED"
      break
    fi

    # Backend verdict check: only at POLL_INTERVAL cadence
    if [[ $elapsed -lt $next_backend_check ]]; then
      continue
    fi
    next_backend_check=$((elapsed + POLL_INTERVAL))

    # Crash/blocked detection: only when a handle file is present (without
    # it, we can't verify the worker). The backend reports the ADR-0018
    # verdict vocabulary; `blocked` (permission-dialog stall) MUST be
    # surfaced as a distinct result — nobody approves a dialog in a
    # headless session, so it is terminal.
    # Degradation policy (ADR-0018 — the consumer decides): query-failed
    # and unknown-value are retried, then ESCALATED after
    # QUERY_RETRY_MAX consecutive unverifiable polls — never coerced
    # into a crash (#573, #581).
    local has_handle=0
    for _hf in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$_hf" ]] && has_handle=1 && break
    done
    if [[ "$has_handle" -eq 1 ]]; then
      local worker_dead=0 worker_detail="Worker process died without completing"
      if declare -F backend_worker_status >/dev/null 2>&1; then
        local wstatus
        wstatus=$(backend_worker_status "$issue" 2>/dev/null) || true
        [[ -n "$wstatus" ]] || wstatus="missing"
        case "$wstatus" in
          alive)
            query_failures=0
            ;;
          blocked)
            query_failures=0
            # ADR-0020 Phase 1: write-once — re-read state before writing.
            # If already TERMINATED, the Worker completed just before the
            # backend reported blocked; consume the existing record.
            state_json=$(worker_state_read "$issue")
            state=$(echo "$state_json" | jq -r '.state')
            if [[ "$state" == "TERMINATED" ]]; then
              result=$(build_result_from_state "$state_json")
              log_event "$issue" "STATE_COMPLETE" "issue=#${issue} state=TERMINATED (write-once, before blocked write)"
              break
            fi
            # ADR-0020: write TERMINATED for blocked (terminal by policy)
            worker_state_write "$issue" TERMINATED "blocked:Worker session is waiting on a permission dialog"
            result="{\"issue\":${issue},\"result\":\"blocked\",\"detail\":\"Worker session is waiting on a permission dialog\"}"
            echo "Error: issue #${issue} Worker session is blocked (permission dialog)." >&2
            log_event "$issue" "WORKER_BLOCKED" "issue=#${issue} state=${state}"
            break
            ;;
          query-failed|unknown-value)
            # Unverifiable — retry, escalate when persistent.
            # ADR-0020: no TERMINATED write (slot held on doubt)
            query_failures=$((query_failures + 1))
            if [[ "$query_failures" -ge "$QUERY_RETRY_MAX" ]]; then
              result="{\"issue\":${issue},\"result\":\"error\",\"detail\":\"agents query unverifiable (${wstatus}) for ${query_failures} consecutive polls — worker may still be running, do not clean up on this result alone\"}"
              echo "Error: issue #${issue} agents query unverifiable (${wstatus}) ${query_failures} times — escalating." >&2
              log_event "$issue" "WATCH_QUERY_ESCALATED" "issue=#${issue} report=${wstatus} failures=${query_failures}"
              break
            fi
            log_event "$issue" "WATCH_QUERY_RETRY" "issue=#${issue} report=${wstatus} failures=${query_failures}"
            ;;
          *)
            # done | stopped | not-listed | missing — verifiably ended
            query_failures=0
            worker_dead=1
            worker_detail="Worker session ended without completing (verdict: ${wstatus})"
            ;;
        esac
      elif ! backend_worker_alive "$issue" 2>/dev/null; then
        worker_dead=1
      fi
      if [[ "$worker_dead" -eq 1 ]]; then
        # ADR-0020 Phase 1: write-once — re-read state before writing.
        # If already TERMINATED, the Worker completed just before the
        # backend reported dead; consume the existing record instead of
        # overwriting with crashed.
        state_json=$(worker_state_read "$issue")
        state=$(echo "$state_json" | jq -r '.state')
        if [[ "$state" == "TERMINATED" ]]; then
          result=$(build_result_from_state "$state_json")
          log_event "$issue" "STATE_COMPLETE" "issue=#${issue} state=TERMINATED (write-once, before crashed write)"
          break
        fi
        # ADR-0020: write TERMINATED for crashed exit
        worker_state_write "$issue" TERMINATED "crashed:${worker_detail}"
        result="{\"issue\":${issue},\"result\":\"crashed\",\"detail\":\"${worker_detail}\"}"
        echo "Error: issue #${issue} Worker process crashed (state: ${state})." >&2
        log_event "$issue" "WORKER_CRASH" "issue=#${issue} state=${state}"
        break
      fi
    fi
  done

  # Timeout: state file did not indicate completion
  # ADR-0020: no TERMINATED write for timeout (slot held — on doubt, refuse to free)
  if [[ -z "$result" ]]; then
    result="{\"issue\":${issue},\"result\":\"timeout\",\"detail\":\"No response within ${TIMEOUT}s\"}"
    echo "Issue #${issue} timed out after ${TIMEOUT}s." >&2
    log_event "$issue" "WATCH_TIMEOUT" "issue=#${issue} timeout=${TIMEOUT}s"
  fi

  echo "$result" > "${RESULT_DIR}/${issue}"
  local result_status
  local result_value
  result_value=$(echo "$result" | jq -r '.result')
  [[ "$result_value" != "timeout" && "$result_value" != "error" && "$result_value" != "crashed" && "$result_value" != "blocked" ]]
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
