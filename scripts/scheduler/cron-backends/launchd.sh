#!/usr/bin/env bash
# launchd.sh — launchd backend for /cron (macOS)
#
# Usage: source launchd.sh
#
# Functions:
#   cron_launchd_register <id> <schedule> <runner_path>       — Register plist and bootstrap
#   cron_launchd_cancel <id>                                  — Bootout and remove plist
#   cron_launchd_is_registered <id>                           — Check if plist is loaded
#   cron_launchd_generate_plist <id> <schedule> <runner_path> — Generate plist XML (stdout)
#
# Internal (exported for testing):
#   _expand_cron_field <field> <min> <max>  — Expand a cron field to integer list
#   _cron_to_calendar_intervals <schedule>  — Convert cron expr to JSON intervals
#
# Environment variables (overridable for testing):
#   CEKERNEL_VAR_DIR     — Runtime directory (default: $HOME/.local/var/cekernel)
#   CEKERNEL_LAUNCHD_DIR — plist directory (default: ~/Library/LaunchAgents)

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
CEKERNEL_LAUNCHD_DIR="${CEKERNEL_LAUNCHD_DIR:-${HOME}/Library/LaunchAgents}"

# Expand a single cron field into a space-separated list of integers.
# Wildcard (*) returns empty string (no constraint).
# Supports: *, N, N-M, */N, N-M/N, and comma-separated combinations.
_expand_cron_field() {
  local field="$1" min="$2" max="$3"

  if [[ "$field" == "*" ]]; then
    return
  fi

  local values=()
  local parts
  IFS=',' read -ra parts <<< "$field"

  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9*]+(-[0-9]+)?)/([0-9]+)$ ]]; then
      # Step: */N or N-M/N
      local range="${BASH_REMATCH[1]}"
      local step="${BASH_REMATCH[3]}"
      local start="$min" end="$max"
      if [[ "$range" != "*" ]]; then
        start="${range%-*}"
        end="${range#*-}"
      fi
      local i
      for ((i = start; i <= end; i += step)); do
        values+=("$i")
      done
    elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      # Range: N-M
      local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
      local i
      for ((i = start; i <= end; i++)); do
        values+=("$i")
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      # Single value
      values+=("$part")
    else
      echo "Error: invalid cron field: $part" >&2
      return 1
    fi
  done

  echo "${values[*]}"
}

# Convert a 5-field cron expression to a JSON array of StartCalendarInterval dicts.
# Day-of-week 7 is normalized to 0 (both mean Sunday).
_cron_to_calendar_intervals() {
  local schedule="$1"

  local f_min f_hour f_dom f_month f_dow
  read -r f_min f_hour f_dom f_month f_dow <<< "$schedule"

  local minutes hours days months weekdays
  minutes=$(_expand_cron_field "$f_min" 0 59) || return 1
  hours=$(_expand_cron_field "$f_hour" 0 23) || return 1
  days=$(_expand_cron_field "$f_dom" 1 31) || return 1
  months=$(_expand_cron_field "$f_month" 1 12) || return 1
  weekdays=$(_expand_cron_field "$f_dow" 0 6) || return 1

  # Normalize day-of-week 7 → 0
  weekdays=$(echo "$weekdays" | tr ' ' '\n' | sed 's/^7$/0/' | tr '\n' ' ' | sed 's/ $//')

  # Convert space-separated values to JSON arrays
  local to_json='if . == "" then [] else split(" ") | map(tonumber) end'
  local j_min j_hour j_dom j_month j_dow
  j_min=$(echo "$minutes" | jq -R "$to_json")
  j_hour=$(echo "$hours" | jq -R "$to_json")
  j_dom=$(echo "$days" | jq -R "$to_json")
  j_month=$(echo "$months" | jq -R "$to_json")
  j_dow=$(echo "$weekdays" | jq -R "$to_json")

  # Cartesian product: generate one dict per combination of specified values
  jq -n \
    --argjson minutes "$j_min" \
    --argjson hours "$j_hour" \
    --argjson days "$j_dom" \
    --argjson months "$j_month" \
    --argjson weekdays "$j_dow" \
    '
    ($minutes  | if length == 0 then [null] else . end) as $ms   |
    ($hours    | if length == 0 then [null] else . end) as $hs   |
    ($days     | if length == 0 then [null] else . end) as $ds   |
    ($months   | if length == 0 then [null] else . end) as $mons |
    ($weekdays | if length == 0 then [null] else . end) as $ws   |
    [
      $ms[] as $m | $hs[] as $h | $ds[] as $d | $mons[] as $mon | $ws[] as $w |
      ({}
        | if $m   != null then .Minute  = $m   else . end
        | if $h   != null then .Hour    = $h   else . end
        | if $d   != null then .Day     = $d   else . end
        | if $mon != null then .Month   = $mon else . end
        | if $w   != null then .Weekday = $w   else . end
      )
    ]
    '
}

# Generate a launchd plist XML for a cron schedule.
cron_launchd_generate_plist() {
  local id="${1:?Usage: cron_launchd_generate_plist <id> <schedule> <runner_path>}"
  local schedule="${2:?Usage: cron_launchd_generate_plist <id> <schedule> <runner_path>}"
  local runner_path="${3:?Usage: cron_launchd_generate_plist <id> <schedule> <runner_path>}"

  local intervals
  intervals=$(_cron_to_calendar_intervals "$schedule") || return 1

  local count
  count=$(echo "$intervals" | jq 'length')

  # Build StartCalendarInterval XML entries
  local interval_xml=""
  local i
  for ((i = 0; i < count; i++)); do
    interval_xml+="            <dict>"$'\n'
    local key
    for key in Minute Hour Day Month Weekday; do
      local val
      val=$(echo "$intervals" | jq -r ".[$i].${key} // empty")
      if [[ -n "$val" ]]; then
        interval_xml+="                <key>${key}</key>"$'\n'
        interval_xml+="                <integer>${val}</integer>"$'\n'
      fi
    done
    interval_xml+="            </dict>"$'\n'
  done

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
        <array>
${interval_xml}        </array>
        <key>StandardOutPath</key>
        <string>${CEKERNEL_VAR_DIR}/logs/${id}.stdout.log</string>
        <key>StandardErrorPath</key>
        <string>${CEKERNEL_VAR_DIR}/logs/${id}.stderr.log</string>
    </dict>
</plist>
PLIST_EOF
}

# Register a cron schedule with launchd.
cron_launchd_register() {
  local id="${1:?Usage: cron_launchd_register <id> <schedule> <runner_path>}"
  local schedule="${2:?Usage: cron_launchd_register <id> <schedule> <runner_path>}"
  local runner_path="${3:?Usage: cron_launchd_register <id> <schedule> <runner_path>}"

  local plist_path="${CEKERNEL_LAUNCHD_DIR}/${id}.plist"

  mkdir -p "$CEKERNEL_LAUNCHD_DIR"
  cron_launchd_generate_plist "$id" "$schedule" "$runner_path" > "$plist_path"
  launchctl bootstrap "gui/$(id -u)" "$plist_path"
}

# Cancel a cron schedule from launchd.
cron_launchd_cancel() {
  local id="${1:?Usage: cron_launchd_cancel <id>}"

  launchctl bootout "gui/$(id -u)/${id}" 2>/dev/null || true
  rm -f "${CEKERNEL_LAUNCHD_DIR}/${id}.plist"
}

# Check if a cron schedule is registered in launchd.
cron_launchd_is_registered() {
  local id="${1:?Usage: cron_launchd_is_registered <id>}"

  launchctl list "$id" >/dev/null 2>&1
}
