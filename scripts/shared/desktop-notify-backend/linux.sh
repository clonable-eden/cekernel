#!/usr/bin/env bash
# desktop-notify-backend/linux.sh — Linux notification adapter (notify-send)
#
# Implements desktop_notify for native Linux using notify-send.
# Sound: best-effort via canberra-gtk-play (if available).
# Icon: logo.png from repository root.
# URL: notify-send --action with xdg-open in background.

# Resolve logo.png path from this script's location
_DESKTOP_NOTIFY_LINUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DESKTOP_NOTIFY_LOGO="${_DESKTOP_NOTIFY_LINUX_DIR}/../../../logo.png"

desktop_notify() {
  local title="${1:?Usage: desktop_notify <title> <message> [url]}"
  local message="${2:?Usage: desktop_notify <title> <message> [url]}"
  local url="${3:-}"

  # Build notify-send arguments
  local -a args=()
  if [[ -f "$_DESKTOP_NOTIFY_LOGO" ]]; then
    args+=(-i "$_DESKTOP_NOTIFY_LOGO")
  fi

  if [[ -n "$url" ]]; then
    # Use --action with --wait in background to handle click → open URL
    (
      notify-send "${args[@]}" --action="open=Open" "${title}" "${message}" --wait 2>/dev/null \
        && xdg-open "$url" 2>/dev/null
    ) &
  else
    notify-send "${args[@]}" "${title}" "${message}" 2>/dev/null || true
  fi

  # Sound: best-effort via canberra-gtk-play
  canberra-gtk-play -i message-new-instant 2>/dev/null || true
}
