#!/usr/bin/env bash
# crontab.sh — crontab backend for /cron (Linux/WSL)
#
# Usage: source crontab.sh
#
# Functions:
#   cron_crontab_register <id> <schedule> <runner_path> — Add entry to crontab
#   cron_crontab_cancel <id>                            — Remove entry from crontab
#   cron_crontab_is_registered <id>                     — Check if entry exists
#   cron_crontab_generate_entry <id> <schedule> <runner_path> — Full entry with comment
#   cron_crontab_generate_line <id> <schedule> <runner_path>  — Crontab line only
#
# Environment variables (overridable for testing):
#   _CRON_CRONTAB_FILE — Mock crontab file (testing only; unset uses real crontab)

# Read current crontab contents
_crontab_read() {
  if [[ -n "${_CRON_CRONTAB_FILE:-}" ]]; then
    cat "$_CRON_CRONTAB_FILE"
  else
    crontab -l 2>/dev/null || true
  fi
}

# Write new crontab contents
_crontab_write() {
  if [[ -n "${_CRON_CRONTAB_FILE:-}" ]]; then
    cat > "$_CRON_CRONTAB_FILE"
  else
    crontab -
  fi
}

# Generate the crontab command line (without comment).
cron_crontab_generate_line() {
  local id="${1:?Usage: cron_crontab_generate_line <id> <schedule> <runner_path>}"
  local schedule="${2:?Usage: cron_crontab_generate_line <id> <schedule> <runner_path>}"
  local runner_path="${3:?Usage: cron_crontab_generate_line <id> <schedule> <runner_path>}"

  echo "${schedule} ${runner_path}"
}

# Generate full crontab entry (comment + command line).
cron_crontab_generate_entry() {
  local id="${1:?Usage: cron_crontab_generate_entry <id> <schedule> <runner_path>}"
  local schedule="${2:?Usage: cron_crontab_generate_entry <id> <schedule> <runner_path>}"
  local runner_path="${3:?Usage: cron_crontab_generate_entry <id> <schedule> <runner_path>}"

  printf '# %s\n%s\n' "$id" "$(cron_crontab_generate_line "$id" "$schedule" "$runner_path")"
}

# Register a cron schedule by appending to crontab.
cron_crontab_register() {
  local id="${1:?Usage: cron_crontab_register <id> <schedule> <runner_path>}"
  local schedule="${2:?Usage: cron_crontab_register <id> <schedule> <runner_path>}"
  local runner_path="${3:?Usage: cron_crontab_register <id> <schedule> <runner_path>}"

  local existing
  existing=$(_crontab_read)

  local entry
  entry=$(cron_crontab_generate_entry "$id" "$schedule" "$runner_path")

  if [[ -n "$existing" ]]; then
    printf '%s\n%s\n' "$existing" "$entry" | _crontab_write
  else
    printf '%s\n' "$entry" | _crontab_write
  fi
}

# Cancel a cron schedule by removing its comment + command line from crontab.
cron_crontab_cancel() {
  local id="${1:?Usage: cron_crontab_cancel <id>}"

  local existing
  existing=$(_crontab_read)

  # Remove the comment line (# <id>) and the line immediately after it
  echo "$existing" | awk -v id="$id" '
    $0 == "# " id { skip = 1; next }
    skip { skip = 0; next }
    { print }
  ' | _crontab_write
}

# Check if a cron schedule is registered in crontab.
cron_crontab_is_registered() {
  local id="${1:?Usage: cron_crontab_is_registered <id>}"

  _crontab_read | grep -q "^# ${id}$"
}
