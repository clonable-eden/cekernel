#!/usr/bin/env bash
# atd.sh — atd backend for /at (Linux/WSL)
#
# Usage: source atd.sh
#
# Functions:
#   at_atd_register <id> <datetime> <runner_path> — Schedule via at command (stdout: job number)
#   at_atd_cancel <os_ref>                        — Remove via atrm
#   at_atd_is_registered <os_ref>                 — Check via atq
#
# Internal (exported for testing):
#   _at_datetime_to_at_time <datetime>            — Convert ISO 8601 to at -t format

# Convert ISO 8601 datetime to at -t format.
# Input: 2026-03-15T09:00
# Output: 202603150900
_at_datetime_to_at_time() {
  local datetime="${1:?Usage: _at_datetime_to_at_time <datetime>}"
  echo "$datetime" | sed 's/[-T:]//g' | cut -c1-12
}

# Register a one-shot job via at command.
# Stdout: os_ref (= at job number)
at_atd_register() {
  local id="${1:?Usage: at_atd_register <id> <datetime> <runner_path>}"
  local datetime="${2:?Usage: at_atd_register <id> <datetime> <runner_path>}"
  local runner_path="${3:?Usage: at_atd_register <id> <datetime> <runner_path>}"

  local at_time
  at_time=$(_at_datetime_to_at_time "$datetime")

  # at outputs job info on stderr
  local output
  output=$(echo "bash \"${runner_path}\"" | at -t "$at_time" 2>&1)

  # Extract job number: "job 42 at ..."
  local job_number
  job_number=$(echo "$output" | grep -o 'job [0-9]*' | head -1 | awk '{print $2}')

  if [[ -z "$job_number" ]]; then
    echo "Error: failed to parse at job number from output: ${output}" >&2
    return 1
  fi

  echo "$job_number"
}

# Cancel a scheduled at job.
at_atd_cancel() {
  local os_ref="${1:?Usage: at_atd_cancel <os_ref>}"
  atrm "$os_ref" 2>/dev/null || true
}

# Check if an at job is still pending.
at_atd_is_registered() {
  local os_ref="${1:?Usage: at_atd_is_registered <os_ref>}"
  atq | grep -q "^${os_ref}[[:space:]]"
}
