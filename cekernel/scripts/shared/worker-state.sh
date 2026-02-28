#!/usr/bin/env bash
# worker-state.sh — Worker process state management
#
# Usage: source worker-state.sh
#
# Provides functions to read/write Worker state files.
# State files live alongside FIFOs in the session IPC directory.
#
# State machine:
#   NEW → READY → RUNNING → WAITING → TERMINATED
#                    ↑↑         ↓
#                    |└─────────┘
#                    └── SUSPENDED (checkpoint saved, can resume)
#
# State file format: STATE:TIMESTAMP:detail (one line, detail may contain colons)
# State file path: ${CEKERNEL_IPC_DIR}/worker-{issue}.state
#
# Functions:
#   worker_state_write <issue-number> <state> [detail]
#   worker_state_read <issue-number>  → JSON to stdout

# Valid states
_CEKERNEL_VALID_STATES="NEW READY RUNNING WAITING SUSPENDED TERMINATED"

# worker_state_write <issue-number> <state> [detail]
#   Write state to the worker state file.
#   Exit 1 if state is invalid.
worker_state_write() {
  local issue="${1:?Usage: worker_state_write <issue-number> <state> [detail]}"
  local state="${2:?State required: NEW|READY|RUNNING|WAITING|SUSPENDED|TERMINATED}"
  local detail="${3:-}"

  # Validate state using case statement (immune to IFS changes — fixes #141)
  case "$state" in
    NEW|READY|RUNNING|WAITING|SUSPENDED|TERMINATED) ;;
    *)
      echo "Error: invalid state '${state}'. Valid: ${_CEKERNEL_VALID_STATES}" >&2
      return 1
      ;;
  esac

  local state_file="${CEKERNEL_IPC_DIR}/worker-${issue}.state"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Atomic write: write to temp file then rename
  # Format: STATE:TIMESTAMP:detail (detail is last because it may contain colons)
  local tmp_file="${state_file}.tmp"
  echo "${state}:${timestamp}:${detail}" > "$tmp_file"
  mv -f "$tmp_file" "$state_file"
}

# worker_state_read <issue-number>
#   Read state from the worker state file.
#   Outputs JSON: {"issue": N, "state": "...", "detail": "...", "timestamp": "..."}
#   Returns UNKNOWN state if no state file exists.
worker_state_read() {
  local issue="${1:?Usage: worker_state_read <issue-number>}"
  local state_file="${CEKERNEL_IPC_DIR}/worker-${issue}.state"

  if [[ ! -f "$state_file" ]]; then
    jq -cn \
      --argjson issue "$issue" \
      '{issue: $issue, state: "UNKNOWN", detail: "", timestamp: ""}'
    return 0
  fi

  local line
  line=$(cat "$state_file")

  # Parse STATE:TIMESTAMP:detail (detail may contain colons)
  local state timestamp detail
  state="${line%%:*}"
  local rest="${line#*:}"
  # Timestamp is fixed 20-char ISO format (YYYY-MM-DDTHH:MM:SSZ)
  timestamp="${rest:0:20}"
  # Detail is everything after STATE:TIMESTAMP:
  detail="${rest:21}"

  jq -cn \
    --argjson issue "$issue" \
    --arg state "$state" \
    --arg detail "$detail" \
    --arg timestamp "$timestamp" \
    '{issue: $issue, state: $state, detail: $detail, timestamp: $timestamp}'
}
