#!/usr/bin/env bash
# desktop-notify-backend/wsl.sh — WSL notification adapter (powershell.exe)
#
# Implements desktop_notify for WSL using PowerShell toast notifications.
# Icon: logo.png converted to Windows path via wslpath.
# URL: activationType="protocol" for click-to-open.
# Sound: system default toast audio.

# Resolve logo.png path from this script's location
_DESKTOP_NOTIFY_WSL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DESKTOP_NOTIFY_LOGO="${_DESKTOP_NOTIFY_WSL_DIR}/../../../logo.png"

desktop_notify() {
  local title="${1:?Usage: desktop_notify <title> <message> [url]}"
  local message="${2:?Usage: desktop_notify <title> <message> [url]}"
  local url="${3:-}"

  # Convert logo path to Windows format
  local win_logo=""
  if [[ -f "$_DESKTOP_NOTIFY_LOGO" ]]; then
    win_logo=$(wslpath -w "$_DESKTOP_NOTIFY_LOGO" 2>/dev/null || echo "")
  fi

  # Build toast XML
  local launch_attr=""
  if [[ -n "$url" ]]; then
    launch_attr="activationType=\"protocol\" launch=\"${url}\""
  fi

  local image_xml=""
  if [[ -n "$win_logo" ]]; then
    image_xml="<image placement=\"appLogoOverride\" src=\"${win_logo}\"/>"
  fi

  local toast_xml="<toast ${launch_attr}><visual><binding template=\"ToastGeneric\"><text>${title}</text><text>${message}</text>${image_xml}</binding></visual><audio src=\"ms-winsoundevent:Notification.Default\"/></toast>"

  # Execute via PowerShell
  powershell.exe -Command "
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    \$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    \$xml.LoadXml('${toast_xml}')
    \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show(\$toast)
  " 2>/dev/null || true
}
