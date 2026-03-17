#!/usr/bin/env bash
# desktop-notify.sh — OS-native desktop notification dispatcher
#
# Sends best-effort desktop notifications using the platform's native tool.
# Detects the platform and delegates to the appropriate backend adapter.
#
# Backends:
#   macos.sh  — osascript (display notification + sound)
#   linux.sh  — notify-send + canberra-gtk-play
#   wsl.sh    — powershell.exe toast notification
#
# Usage: source desktop-notify.sh
#
# Functions:
#   desktop_notify <title> <message> [url] — Send a desktop notification (best-effort, never fails)
#
# Environment:
#   CEKERNEL_NOTIFY_MACOS_ACTION — macOS URL action mode (none|open|pbcopy, default: none)

_DESKTOP_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"

# Detect platform and source the appropriate backend
_desktop_notify_platform() {
  case "$(uname)" in
    Darwin)
      echo "macos"
      ;;
    Linux)
      # Distinguish WSL from native Linux
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    *)
      echo "unsupported"
      ;;
  esac
}

_DESKTOP_NOTIFY_PLATFORM="$(_desktop_notify_platform)"
_DESKTOP_NOTIFY_BACKEND="${_DESKTOP_NOTIFY_DIR}/desktop-notify-backend/${_DESKTOP_NOTIFY_PLATFORM}.sh"

if [[ -f "$_DESKTOP_NOTIFY_BACKEND" ]]; then
  source "$_DESKTOP_NOTIFY_BACKEND"
else
  # Unsupported platform — provide a no-op function
  desktop_notify() {
    local title="${1:?Usage: desktop_notify <title> <message> [url]}"
    local message="${2:?Usage: desktop_notify <title> <message> [url]}"
    # Best-effort: silently do nothing on unsupported platforms
    return 0
  }
fi
