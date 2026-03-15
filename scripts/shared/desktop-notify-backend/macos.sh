#!/usr/bin/env bash
# desktop-notify-backend/macos.sh — macOS notification adapter (osascript)
#
# Implements desktop_notify for macOS using osascript's display notification.
#
# Environment:
#   CEKERNEL_NOTIFY_MACOS_ACTION — URL action mode (default: none)
#     none   — Notification + sound only; URL ignored
#     open   — Auto-open URL in default browser via `open`
#     pbcopy — Copy URL to clipboard via `pbcopy`

desktop_notify() {
  local title="${1:?Usage: desktop_notify <title> <message> [url]}"
  local message="${2:?Usage: desktop_notify <title> <message> [url]}"
  local url="${3:-}"

  # Display notification with sound
  osascript -e "display notification \"${message}\" with title \"${title}\" sound name \"Glass\"" 2>/dev/null || true

  # Handle URL based on CEKERNEL_NOTIFY_MACOS_ACTION
  if [[ -n "$url" ]]; then
    local action="${CEKERNEL_NOTIFY_MACOS_ACTION:-none}"
    case "$action" in
      open)
        open "$url" 2>/dev/null || true ;;
      pbcopy)
        echo -n "$url" | pbcopy 2>/dev/null || true ;;
      none|*)
        # Do nothing — notification + sound only
        ;;
    esac
  fi
}
