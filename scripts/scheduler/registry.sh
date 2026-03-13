#!/usr/bin/env bash
# registry.sh — Registry CRUD for schedule entries
#
# Usage: source registry.sh
#
# Functions:
#   schedule_registry_add <json-entry>           — Add entry to registry
#   schedule_registry_list [--type <cron|at>]     — List entries (optionally filtered)
#   schedule_registry_remove <id>                 — Remove entry by ID (idempotent)
#   schedule_registry_update_status <id> <status> — Update last_run_status and last_run_at
#   schedule_registry_get <id>                    — Get single entry (exit 1 if not found)
#
# Environment variables (overridable for testing):
#   CEKERNEL_VAR_DIR — Base directory (default: /usr/local/var/cekernel)

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not found. Install it: https://jqlang.github.io/jq/download/" >&2
  return 1
fi

_REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_REGISTRY_DIR}/../shared/load-env.sh"

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}"
CEKERNEL_REGISTRY="${CEKERNEL_VAR_DIR}/schedules.json"
CEKERNEL_REGISTRY_LOCK="${CEKERNEL_REGISTRY}.lock"

acquire_schedule_registry_lock() {
  local max_wait=10
  local waited=0
  while ! mkdir "$CEKERNEL_REGISTRY_LOCK" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ "$waited" -ge "$max_wait" ]]; then
      echo "Error: failed to acquire registry lock after ${max_wait}s" >&2
      return 1
    fi
    sleep 1
  done
}

release_schedule_registry_lock() {
  rmdir "$CEKERNEL_REGISTRY_LOCK" 2>/dev/null || true
}

schedule_registry_add() {
  local entry="${1:?Usage: schedule_registry_add <json-entry>}"

  acquire_schedule_registry_lock || return 1
  trap 'release_schedule_registry_lock' RETURN

  local id
  id=$(echo "$entry" | jq -r '.id')
  if jq -e --arg id "$id" '.[] | select(.id == $id)' "$CEKERNEL_REGISTRY" >/dev/null 2>&1; then
    echo "Error: schedule entry already exists: ${id}" >&2
    return 1
  fi

  local tmp="${CEKERNEL_REGISTRY}.tmp.$$"
  jq --argjson entry "$entry" '. + [$entry]' "$CEKERNEL_REGISTRY" > "$tmp" \
    && mv "$tmp" "$CEKERNEL_REGISTRY"
}

schedule_registry_list() {
  local type_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type_filter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -n "$type_filter" ]]; then
    jq --arg type "$type_filter" '[.[] | select(.type == $type)]' "$CEKERNEL_REGISTRY"
  else
    jq '.' "$CEKERNEL_REGISTRY"
  fi
}

schedule_registry_get() {
  local id="${1:?Usage: schedule_registry_get <id>}"

  local result
  result=$(jq --arg id "$id" '.[] | select(.id == $id)' "$CEKERNEL_REGISTRY")

  if [[ -z "$result" ]]; then
    echo "Error: schedule entry not found: ${id}" >&2
    return 1
  fi

  echo "$result"
}

schedule_registry_remove() {
  local id="${1:?Usage: schedule_registry_remove <id>}"

  acquire_schedule_registry_lock || return 1
  trap 'release_schedule_registry_lock' RETURN

  local tmp="${CEKERNEL_REGISTRY}.tmp.$$"
  jq --arg id "$id" '[.[] | select(.id != $id)]' "$CEKERNEL_REGISTRY" > "$tmp" \
    && mv "$tmp" "$CEKERNEL_REGISTRY"
}

schedule_registry_update_status() {
  local id="${1:?Usage: schedule_registry_update_status <id> <status>}"
  local status="${2:?Usage: schedule_registry_update_status <id> <status>}"

  acquire_schedule_registry_lock || return 1
  trap 'release_schedule_registry_lock' RETURN

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local tmp="${CEKERNEL_REGISTRY}.tmp.$$"
  jq --arg id "$id" --arg status "$status" --arg now "$now" '
    [.[] | if .id == $id then .last_run_status = $status | .last_run_at = $now else . end]
  ' "$CEKERNEL_REGISTRY" > "$tmp" \
    && mv "$tmp" "$CEKERNEL_REGISTRY"
}
