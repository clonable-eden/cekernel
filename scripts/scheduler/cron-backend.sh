#!/usr/bin/env bash
# cron-backend.sh — Platform adapter for /cron backends
#
# Usage: source cron-backend.sh
#
# Functions:
#   cron_backend_detect                                     — Returns "launchd" or "crontab"
#   cron_backend_register <id> <schedule> <runner_path>     — Register with OS scheduler
#   cron_backend_cancel <id>                                — Remove from OS scheduler
#   cron_backend_is_registered <id>                         — Check if entry exists in OS scheduler
#
# Dispatches to cron-backends/launchd.sh (macOS) or cron-backends/crontab.sh (Linux/WSL).

_CRON_BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/cron-backends" && pwd)"

cron_backend_detect() {
  case "$(uname)" in
    Darwin) echo "launchd" ;;
    *)      echo "crontab" ;;
  esac
}

# Source the appropriate backend
_cron_backend=$(cron_backend_detect)
source "${_CRON_BACKEND_DIR}/${_cron_backend}.sh"

cron_backend_register() {
  case "$_cron_backend" in
    launchd) cron_launchd_register "$@" ;;
    crontab) cron_crontab_register "$@" ;;
  esac
}

cron_backend_cancel() {
  case "$_cron_backend" in
    launchd) cron_launchd_cancel "$@" ;;
    crontab) cron_crontab_cancel "$@" ;;
  esac
}

cron_backend_is_registered() {
  case "$_cron_backend" in
    launchd) cron_launchd_is_registered "$@" ;;
    crontab) cron_crontab_is_registered "$@" ;;
  esac
}
