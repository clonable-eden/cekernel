#!/usr/bin/env bash
# format-elapsed.sh — Render elapsed seconds as a compact h/m/s string
#
# Usage: source format-elapsed.sh
#
# Functions:
#   format_elapsed <seconds>
#     — Echo the elapsed time: "{N}s" below 60, "{N}m" below 3600,
#       "{H}h{M}m" from 3600 up
#
# Shared by orchctl.sh (ls/ps elapsed column) and process-status.sh
# (uptime field).

# format_elapsed <seconds>
format_elapsed() {
  local elapsed="$1"
  if [[ $elapsed -ge 3600 ]]; then
    echo "$((elapsed / 3600))h$((elapsed % 3600 / 60))m"
  elif [[ $elapsed -ge 60 ]]; then
    echo "$((elapsed / 60))m"
  else
    echo "${elapsed}s"
  fi
}
