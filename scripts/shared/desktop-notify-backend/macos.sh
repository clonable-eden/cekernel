#!/usr/bin/env bash
# desktop-notify-backend/macos.sh — macOS notification adapter (alerter / osascript)
#
# Implements desktop_notify for macOS using alerter (preferred) or osascript (fallback).
#
# Tool priority:
#   1. alerter   — if available (e.g. brew install vjeantet/tap/alerter)
#   2. osascript — fallback (always available on macOS)
#
# URL handling:
#   alerter:   Runs in background; `open URL` is called when the notification is clicked.
#              (alerter exits 0 on click, non-zero on dismiss/timeout)
#   osascript: URL action is controlled by CEKERNEL_NOTIFY_MACOS_ACTION (see below).
#              CEKERNEL_NOTIFY_MACOS_ACTION is ignored when alerter is used.
#
# Environment (osascript fallback only):
#   CEKERNEL_NOTIFY_MACOS_ACTION — URL action mode (default: none)
#     none   — Notification + sound only; URL ignored
#     open   — Auto-open URL in default browser via `open`
#     pbcopy — Copy URL to clipboard via `pbcopy`
#
# Note on custom icons: macOS 11+ ignores custom -appIcon in the notification center.
# Since macOS 11+ covers ~100% of users as of 2026, icon support is out of scope.

# Detect preferred backend at source time
_DESKTOP_NOTIFY_MACOS_BACKEND=""
if command -v alerter >/dev/null 2>&1; then
  _DESKTOP_NOTIFY_MACOS_BACKEND="alerter"
fi

desktop_notify() {
  local title="${1:?Usage: desktop_notify <title> <message> [url]}"
  local message="${2:?Usage: desktop_notify <title> <message> [url]}"
  local url="${3:-}"

  if [[ "$_DESKTOP_NOTIFY_MACOS_BACKEND" == "alerter" ]]; then
    # Use alerter: run in background; open URL on click (alerter exits 0 on click)
    if [[ -n "$url" ]]; then
      (alerter --message "$message" --title "$title" --sound "Glass" 2>/dev/null \
        && open "$url" 2>/dev/null) &
    else
      alerter --message "$message" --title "$title" --sound "Glass" 2>/dev/null &
    fi
  else
    # Fallback: osascript (always available on macOS)
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
  fi
}
