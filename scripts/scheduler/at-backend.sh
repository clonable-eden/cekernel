#!/usr/bin/env bash
# at-backend.sh — Platform adapter for /at backends
#
# Usage: source at-backend.sh
#
# Functions:
#   at_backend_detect                                     — Returns "launchd" or "atd"
#   at_backend_register <id> <datetime> <runner_path>     — Register with OS scheduler (stdout: os_ref)
#   at_backend_cancel <os_ref>                            — Remove from OS scheduler
#   at_backend_is_registered <os_ref>                     — Check if entry exists in OS scheduler
#
# Dispatches to at-backends/launchd.sh (macOS) or at-backends/atd.sh (Linux/WSL).

_AT_BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/at-backends" && pwd)"

at_backend_detect() {
  case "$(uname)" in
    Darwin) echo "launchd" ;;
    *)      echo "atd" ;;
  esac
}

# Source the appropriate backend
_at_backend=$(at_backend_detect)
source "${_AT_BACKEND_DIR}/${_at_backend}.sh"

at_backend_register() {
  case "$_at_backend" in
    launchd) at_launchd_register "$@" ;;
    atd)     at_atd_register "$@" ;;
  esac
}

at_backend_cancel() {
  case "$_at_backend" in
    launchd) at_launchd_cancel "$@" ;;
    atd)     at_atd_cancel "$@" ;;
  esac
}

at_backend_is_registered() {
  case "$_at_backend" in
    launchd) at_launchd_is_registered "$@" ;;
    atd)     at_atd_is_registered "$@" ;;
  esac
}
