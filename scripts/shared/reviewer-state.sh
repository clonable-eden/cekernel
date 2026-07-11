#!/usr/bin/env bash
# reviewer-state.sh — Reviewer process state management (#627, ADR-0021)
#
# Usage: source reviewer-state.sh
#
# Provides functions to read/write/enumerate Reviewer state files.
# Reviewer state is kept separate from Worker state to avoid interference
# with worker-specific machinery (spawn count, health-check, gc worker
# sweep — see ADR-0021 OQ1/OQ2).
#
# State machine (simpler than Worker):
#   REVIEWING → TERMINATED (with verdict as detail)
#
# State file format: STATE:TIMESTAMP:detail (one line, detail may contain colons)
# State file path: ${CEKERNEL_IPC_DIR}/reviewer-{issue}.state
#
# Functions:
#   reviewer_state_write <issue-number> <state> [detail]
#   reviewer_state_read <issue-number>  → JSON to stdout
#   reviewer_state_list_active <ipc-dir>  → issue numbers (non-TERMINATED), one per line

# Valid states for Reviewer
_CEKERNEL_REVIEWER_VALID_STATES="REVIEWING TERMINATED"

# Valid verdicts for TERMINATED state (ADR-0021 Amendment 2, β)
_CEKERNEL_REVIEWER_VALID_VERDICTS="approved changes-requested failed"

# reviewer_state_list_active <ipc-dir>
#   List issue numbers of non-TERMINATED reviewers in the given IPC directory.
#   Outputs one issue number per line, sorted.
#   Used by orchctl ls/ps to enumerate active reviewers.
reviewer_state_list_active() {
  local ipc_dir="${1:?Usage: reviewer_state_list_active <ipc-dir>}"

  for state_file in "${ipc_dir}"/reviewer-*.state; do
    [[ -f "$state_file" ]] || continue
    local fname issue state line
    fname=$(basename "$state_file")
    issue="${fname#reviewer-}"
    issue="${issue%.state}"
    line=$(cat "$state_file")
    state="${line%%:*}"
    if [[ "$state" != "TERMINATED" ]]; then
      echo "$issue"
    fi
  done | sort -n
}

# reviewer_state_write <issue-number> <state> [detail]
#   Write state to the reviewer state file.
#   Exit 1 if state is invalid or CEKERNEL_IPC_DIR is not set.
reviewer_state_write() {
  if [[ -z "${CEKERNEL_IPC_DIR:-}" ]]; then
    echo "Error: CEKERNEL_IPC_DIR not set. Source session-id.sh first." >&2
    return 1
  fi

  local issue="${1:?Usage: reviewer_state_write <issue-number> <state> [detail]}"
  local state="${2:?State required: REVIEWING|TERMINATED}"
  local detail="${3:-}"

  # Validate state
  case "$state" in
    REVIEWING|TERMINATED) ;;
    *)
      echo "Error: invalid reviewer state '${state}'. Valid: ${_CEKERNEL_REVIEWER_VALID_STATES}" >&2
      return 1
      ;;
  esac

  # Validate verdict for TERMINATED state (ADR-0021 Amendment 2, β)
  if [[ "$state" == "TERMINATED" ]]; then
    case "$detail" in
      approved|changes-requested|failed) ;;
      *)
        echo "Error: invalid reviewer verdict '${detail}'. Valid: ${_CEKERNEL_REVIEWER_VALID_VERDICTS}" >&2
        return 1
        ;;
    esac
  fi

  local state_file="${CEKERNEL_IPC_DIR}/reviewer-${issue}.state"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Atomic write: write to temp file then rename
  local tmp_file="${state_file}.tmp"
  echo "${state}:${timestamp}:${detail}" > "$tmp_file"
  mv -f "$tmp_file" "$state_file"
}

# reviewer_state_read <issue-number>
#   Read state from the reviewer state file.
#   Outputs JSON: {"issue": N, "state": "...", "detail": "...", "timestamp": "..."}
#   Returns UNKNOWN state if no state file exists.
#   Exit 1 if CEKERNEL_IPC_DIR is not set.
reviewer_state_read() {
  if [[ -z "${CEKERNEL_IPC_DIR:-}" ]]; then
    echo "Error: CEKERNEL_IPC_DIR not set. Source session-id.sh first." >&2
    return 1
  fi

  local issue="${1:?Usage: reviewer_state_read <issue-number>}"
  local state_file="${CEKERNEL_IPC_DIR}/reviewer-${issue}.state"

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
