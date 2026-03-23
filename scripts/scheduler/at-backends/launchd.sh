#!/usr/bin/env bash
# launchd.sh — launchd backend for /at (macOS)
#
# One-shot scheduling via StartCalendarInterval (single dict).
# The register function injects launchctl bootout into the runner
# script for automatic cleanup after execution.
#
# Usage: source launchd.sh
#
# Functions:
#   at_launchd_register <id> <datetime> <runner_path> — Inject cleanup, generate plist, bootstrap (stdout: os_ref)
#   at_launchd_cancel <id>                            — Bootout and remove plist
#   at_launchd_is_registered <id>                     — Check if plist is loaded
#   at_launchd_generate_plist <id> <datetime> <runner_path> — Generate plist XML (stdout)
#
# Internal (exported for testing):
#   _at_parse_datetime <datetime>                     — Parse ISO 8601 into _AT_{MONTH,DAY,HOUR,MINUTE}
#   _at_launchd_inject_cleanup <id> <runner_path>     — Add bootout to runner script
#
# Environment variables (overridable for testing):
#   CEKERNEL_VAR_DIR     — Runtime directory (default: $HOME/.local/var/cekernel)
#   CEKERNEL_LAUNCHD_DIR — plist directory (default: ~/Library/LaunchAgents)

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
CEKERNEL_LAUNCHD_DIR="${CEKERNEL_LAUNCHD_DIR:-${HOME}/Library/LaunchAgents}"

# Parse ISO 8601 datetime into components.
# Input: 2026-03-15T09:00 or 2026-03-15T09:00:00
# Sets: _AT_MONTH, _AT_DAY, _AT_HOUR, _AT_MINUTE
_at_parse_datetime() {
  local datetime="${1:?Usage: _at_parse_datetime <datetime>}"

  local date_part="${datetime%%T*}"
  local time_part="${datetime#*T}"

  # date_part: 2026-03-15
  local rest="${date_part#*-}"
  local month="${rest%%-*}"
  local day="${rest#*-}"

  # time_part: 09:00 or 09:00:00
  local hour="${time_part%%:*}"
  local min_rest="${time_part#*:}"
  local minute="${min_rest%%:*}"

  # Remove leading zeros via base-10 arithmetic
  _AT_MONTH=$((10#$month))
  _AT_DAY=$((10#$day))
  _AT_HOUR=$((10#$hour))
  _AT_MINUTE=$((10#$minute))
}

# Generate a launchd plist XML for a one-shot schedule.
# Uses a single StartCalendarInterval dict (not array).
at_launchd_generate_plist() {
  local id="${1:?Usage: at_launchd_generate_plist <id> <datetime> <runner_path>}"
  local datetime="${2:?Usage: at_launchd_generate_plist <id> <datetime> <runner_path>}"
  local runner_path="${3:?Usage: at_launchd_generate_plist <id> <datetime> <runner_path>}"

  _at_parse_datetime "$datetime"

  cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>${id}</string>
        <key>ProgramArguments</key>
        <array>
            <string>/bin/bash</string>
            <string>${runner_path}</string>
        </array>
        <key>StartCalendarInterval</key>
        <dict>
            <key>Month</key>
            <integer>${_AT_MONTH}</integer>
            <key>Day</key>
            <integer>${_AT_DAY}</integer>
            <key>Hour</key>
            <integer>${_AT_HOUR}</integer>
            <key>Minute</key>
            <integer>${_AT_MINUTE}</integer>
        </dict>
        <key>StandardOutPath</key>
        <string>${CEKERNEL_VAR_DIR}/logs/${id}.stdout.log</string>
        <key>StandardErrorPath</key>
        <string>${CEKERNEL_VAR_DIR}/logs/${id}.stderr.log</string>
    </dict>
</plist>
PLIST_EOF
}

# Inject launchctl bootout into runner script for one-shot cleanup.
_at_launchd_inject_cleanup() {
  local id="${1:?Usage: _at_launchd_inject_cleanup <id> <runner_path>}"
  local runner_path="${2:?Usage: _at_launchd_inject_cleanup <id> <runner_path>}"

  local tmp
  tmp=$(mktemp)
  awk -v id="$id" '
    /^exit / {
      print "# One-shot cleanup: unload from launchd"
      print "launchctl bootout \"gui/$(id -u)/" id "\" 2>/dev/null || true"
      print ""
    }
    { print }
  ' "$runner_path" > "$tmp"
  mv "$tmp" "$runner_path"
  chmod 700 "$runner_path"
}

# Register a one-shot schedule with launchd.
# Stdout: os_ref (= id)
at_launchd_register() {
  local id="${1:?Usage: at_launchd_register <id> <datetime> <runner_path>}"
  local datetime="${2:?Usage: at_launchd_register <id> <datetime> <runner_path>}"
  local runner_path="${3:?Usage: at_launchd_register <id> <datetime> <runner_path>}"

  # Inject one-shot cleanup into runner
  _at_launchd_inject_cleanup "$id" "$runner_path"

  # Generate plist and load
  local plist_path="${CEKERNEL_LAUNCHD_DIR}/${id}.plist"
  mkdir -p "$CEKERNEL_LAUNCHD_DIR"
  at_launchd_generate_plist "$id" "$datetime" "$runner_path" > "$plist_path"
  launchctl bootstrap "gui/$(id -u)" "$plist_path"

  echo "$id"
}

# Cancel a one-shot schedule from launchd.
at_launchd_cancel() {
  local id="${1:?Usage: at_launchd_cancel <id>}"

  launchctl bootout "gui/$(id -u)/${id}" 2>/dev/null || true
  rm -f "${CEKERNEL_LAUNCHD_DIR}/${id}.plist"
}

# Check if a one-shot schedule is registered in launchd.
at_launchd_is_registered() {
  local id="${1:?Usage: at_launchd_is_registered <id>}"

  launchctl list "$id" >/dev/null 2>&1
}
