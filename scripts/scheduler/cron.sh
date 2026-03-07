#!/usr/bin/env bash
# cron.sh — Recurring schedule management (/cron skill backend)
#
# Usage: cron.sh <command> [args...]
#
# Commands:
#   register --label <label> --schedule "<cron-expr>" [--repo <path>]
#   list
#   cancel <id>
#
# Exit codes:
#   0 — Success
#   1 — Error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/registry.sh"
source "${SCRIPT_DIR}/wrapper.sh"
source "${SCRIPT_DIR}/preflight.sh"
source "${SCRIPT_DIR}/cron-backend.sh"

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}"

# ── Usage ──
usage() {
  cat >&2 <<'USAGE'
Usage: cron.sh <command> [args...]

Commands:
  register --label <label> --schedule "<cron-expr>" [--repo <path>]
  list
  cancel <id>
USAGE
  return 1
}

# ── register: Register a recurring schedule ──
cmd_register() {
  local label="" schedule="" repo=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="${2:?--label requires a value}"; shift 2 ;;
      --schedule) schedule="${2:?--schedule requires a value}"; shift 2 ;;
      --repo) repo="${2:?--repo requires a value}"; shift 2 ;;
      *) echo "Error: unknown option: $1" >&2; return 1 ;;
    esac
  done

  [[ -n "$label" ]] || { echo "Error: --label is required" >&2; return 1; }
  [[ -n "$schedule" ]] || { echo "Error: --schedule is required" >&2; return 1; }

  repo="${repo:-$(pwd)}"

  # 1. Preflight check
  echo "Running preflight checks..."
  schedule_preflight_check cron "$repo" || return 1

  # 2. Generate ID
  local id
  id="cekernel-cron-$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"

  # 3. Generate wrapper script
  schedule_generate_wrapper "$id" "$repo" "$PATH" "$label"
  local runner="${CEKERNEL_VAR_DIR}/runners/${id}.sh"

  # 4. Register with OS scheduler
  if ! cron_backend_register "$id" "$schedule" "$runner"; then
    echo "Error: failed to register with OS scheduler" >&2
    rm -f "$runner"
    return 1
  fi

  # 5. Add to registry
  local backend created_at entry
  backend=$(cron_backend_detect)
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  entry=$(jq -n \
    --arg id "$id" \
    --arg type "cron" \
    --arg schedule "$schedule" \
    --arg label "$label" \
    --arg repo "$repo" \
    --arg path "$PATH" \
    --arg os_backend "$backend" \
    --arg os_ref "$id" \
    --arg created_at "$created_at" \
    '{id: $id, type: $type, schedule: $schedule, label: $label, repo: $repo, path: $path, os_backend: $os_backend, os_ref: $os_ref, created_at: $created_at, last_run_at: null, last_run_status: null}')

  if ! schedule_registry_add "$entry"; then
    echo "Error: failed to add to registry, rolling back" >&2
    cron_backend_cancel "$id"
    rm -f "$runner"
    return 1
  fi

  echo ""
  echo "Registered: ${id}"
  echo "  Schedule:  ${schedule}"
  echo "  Label:     ${label}"
  echo "  Repo:      ${repo}"
  echo "  Backend:   ${backend}"
  echo "  Runner:    ${runner}"
}

# ── list: List all cron schedules ──
cmd_list() {
  local entries
  entries=$(schedule_registry_list --type cron)

  local count
  count=$(echo "$entries" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    echo "No cron schedules registered."
    return 0
  fi

  # Header
  printf '%-24s %-16s %-10s %-20s %-22s %-8s %s\n' \
    "ID" "Schedule" "Label" "Repo" "Last Run" "Status" ""

  local i
  for ((i = 0; i < count; i++)); do
    local id schedule_val label repo last_run status os_ref drift_flag
    id=$(echo "$entries" | jq -r ".[$i].id")
    schedule_val=$(echo "$entries" | jq -r ".[$i].schedule")
    label=$(echo "$entries" | jq -r ".[$i].label")
    repo=$(echo "$entries" | jq -r ".[$i].repo" | xargs basename)
    last_run=$(echo "$entries" | jq -r ".[$i].last_run_at // \"(never)\"")
    status=$(echo "$entries" | jq -r ".[$i].last_run_status // \"-\"")
    os_ref=$(echo "$entries" | jq -r ".[$i].os_ref")

    # Drift detection
    drift_flag=""
    if ! cron_backend_is_registered "$os_ref" 2>/dev/null; then
      drift_flag="[drifted]"
    fi

    printf '%-24s %-16s %-10s %-20s %-22s %-8s %s\n' \
      "$id" "$schedule_val" "$label" "$repo" "$last_run" "$status" "$drift_flag"
  done
}

# ── cancel: Cancel a cron schedule ──
cmd_cancel() {
  local id="${1:?Usage: cron.sh cancel <id>}"

  # 1. Verify entry exists
  if ! schedule_registry_get "$id" >/dev/null 2>&1; then
    echo "Error: schedule entry not found: ${id}" >&2
    echo "Run: cron.sh list" >&2
    return 1
  fi

  # 2. Remove from OS scheduler
  cron_backend_cancel "$id"

  # 3. Remove runner script
  rm -f "${CEKERNEL_VAR_DIR}/runners/${id}.sh"

  # 4. Remove from registry
  schedule_registry_remove "$id"

  echo "Cancelled: ${id}"
}

# ══════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  register) cmd_register "$@" ;;
  list)     cmd_list "$@" ;;
  cancel)   cmd_cancel "$@" ;;
  *)        usage ;;
esac
