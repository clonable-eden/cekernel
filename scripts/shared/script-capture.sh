#!/usr/bin/env bash
# script-capture.sh — Cross-platform `script` command wrapper for stdout/stderr capture
#
# Usage: source script-capture.sh
#
# Functions:
#   build_script_capture_cmd <log_file> <command>
#     Builds a `script` command string that captures stdout/stderr to log_file.
#     Handles macOS (BSD) vs Linux (GNU) differences.
#     stdout: the complete command string ready for shell execution
#
#   ensure_log_dir
#     Creates ${CEKERNEL_IPC_DIR}/logs/ if it doesn't exist.
#
# macOS (BSD):  script -q <logfile> <command...>
# Linux (GNU):  script -q -c "<command>" <logfile>

# build_script_capture_cmd <log_file> <command>
build_script_capture_cmd() {
  local log_file="${1:?Usage: build_script_capture_cmd <log_file> <command>}"
  local cmd="${2:?Usage: build_script_capture_cmd <log_file> <command>}"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS (BSD): script -q <logfile> <shell> -c <command>
    echo "script -q ${log_file} bash -c ${cmd}"
  else
    # Linux (GNU): script -q -c <command> <logfile>
    echo "script -q -c ${cmd} ${log_file}"
  fi
}

# ensure_log_dir
# Creates the log directory under CEKERNEL_IPC_DIR.
ensure_log_dir() {
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
}
