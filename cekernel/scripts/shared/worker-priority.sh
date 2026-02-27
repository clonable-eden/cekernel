#!/usr/bin/env bash
# worker-priority.sh — Worker priority (nice value) management
#
# Usage: source worker-priority.sh
#
# Provides functions to read/write Worker priority files.
# Priority files live alongside FIFOs and state files in the session IPC directory.
#
# Nice value range: 0-19 (lower = higher priority, like Unix nice)
#   critical = 0
#   high     = 5
#   normal   = 10 (default)
#   low      = 15
#
# Priority file format: single line containing numeric nice value
# Priority file path: ${CEKERNEL_IPC_DIR}/worker-{issue}.priority
#
# Functions:
#   worker_priority_write <issue-number> <priority>  (name or number)
#   worker_priority_read <issue-number>  → JSON to stdout

# worker_priority_resolve <priority>
#   Resolve named priority to numeric nice value.
#   Accepts: critical, high, normal, low, or numeric 0-19
#   Outputs numeric value to stdout. Returns 1 if invalid.
worker_priority_resolve() {
  local priority="${1:?Usage: worker_priority_resolve <priority>}"

  case "$priority" in
    critical) echo "0"; return 0 ;;
    high)     echo "5"; return 0 ;;
    normal)   echo "10"; return 0 ;;
    low)      echo "15"; return 0 ;;
  esac

  # Validate numeric range 0-19
  if [[ "$priority" =~ ^[0-9]+$ ]] && [[ "$priority" -ge 0 ]] && [[ "$priority" -le 19 ]]; then
    echo "$priority"
    return 0
  fi

  echo "Error: invalid priority '${priority}'. Use: critical|high|normal|low or 0-19" >&2
  return 1
}

# worker_priority_name <nice-value>
#   Map numeric nice value to closest named priority.
#   0-2 → critical, 3-7 → high, 8-12 → normal, 13-19 → low
worker_priority_name() {
  local nice="${1:?Usage: worker_priority_name <nice-value>}"

  if [[ "$nice" -le 2 ]]; then
    echo "critical"
  elif [[ "$nice" -le 7 ]]; then
    echo "high"
  elif [[ "$nice" -le 12 ]]; then
    echo "normal"
  else
    echo "low"
  fi
}

# worker_priority_write <issue-number> <priority>
#   Write priority to the worker priority file.
#   Accepts named priority (critical/high/normal/low) or numeric (0-19).
#   Exit 1 if priority is invalid.
worker_priority_write() {
  local issue="${1:?Usage: worker_priority_write <issue-number> <priority>}"
  local priority="${2:?Priority required: critical|high|normal|low or 0-19}"

  local nice_value
  nice_value=$(worker_priority_resolve "$priority") || return 1

  local priority_file="${CEKERNEL_IPC_DIR}/worker-${issue}.priority"

  # Atomic write: write to temp file then rename
  local tmp_file="${priority_file}.tmp"
  echo "$nice_value" > "$tmp_file"
  mv -f "$tmp_file" "$priority_file"
}

# worker_priority_read <issue-number>
#   Read priority from the worker priority file.
#   Outputs JSON: {"issue": N, "priority": 10, "priority_name": "normal"}
#   Returns default (normal/10) if no priority file exists.
worker_priority_read() {
  local issue="${1:?Usage: worker_priority_read <issue-number>}"
  local priority_file="${CEKERNEL_IPC_DIR}/worker-${issue}.priority"

  local nice_value=10  # default: normal

  if [[ -f "$priority_file" ]]; then
    nice_value=$(tr -d '[:space:]' < "$priority_file")
  fi

  local name
  name=$(worker_priority_name "$nice_value")

  jq -cn \
    --argjson issue "$issue" \
    --argjson priority "$nice_value" \
    --arg priority_name "$name" \
    '{issue: $issue, priority: $priority, priority_name: $priority_name}'
}
