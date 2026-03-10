#!/usr/bin/env bash
# desktop-notify.sh — OS-native desktop notification helper
#
# Sends best-effort desktop notifications using the platform's native tool.
# macOS: osascript (display notification)
# Linux: notify-send
#
# Usage: source desktop-notify.sh
#
# Functions:
#   desktop_notify <title> <message> — Send a desktop notification (best-effort, never fails)

desktop_notify() {
  local title="${1:?Usage: desktop_notify <title> <message>}"
  local message="${2:?Usage: desktop_notify <title> <message>}"

  case "$(uname)" in
    Darwin)
      osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true ;;
    Linux)
      notify-send "${title}" "${message}" 2>/dev/null || true ;;
  esac
}
