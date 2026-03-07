#!/usr/bin/env bash
# test-registry.sh — Tests for scheduler/registry.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY_SCRIPT="${CEKERNEL_DIR}/scripts/scheduler/registry.sh"

echo "test: scheduler/registry.sh"

# ── Setup: isolated temp directory ──
setup() {
  export CEKERNEL_SCHEDULE_DIR="$(mktemp -d)"
  echo '[]' > "${CEKERNEL_SCHEDULE_DIR}/schedules.json"
  source "$REGISTRY_SCRIPT"
}

teardown() {
  rm -rf "$CEKERNEL_SCHEDULE_DIR"
}

SAMPLE_ENTRY='{"id":"cekernel-cron-abc123","type":"cron","schedule":"0 9 * * 1-5","label":"ready","repo":"/tmp/test-repo","path":"/usr/bin:/bin","os_backend":"launchd","os_ref":"cekernel-cron-abc123","created_at":"2026-03-01T10:00:00Z","last_run_at":null,"last_run_status":null}'

SAMPLE_AT_ENTRY='{"id":"cekernel-at-def456","type":"at","schedule":"2026-03-15T09:00","label":"deploy","repo":"/tmp/test-repo","path":"/usr/bin:/bin","os_backend":"launchd","os_ref":"cekernel-at-def456","created_at":"2026-03-01T11:00:00Z","last_run_at":null,"last_run_status":null}'

# ── Test 1: list on empty registry returns empty array ──
setup
RESULT=$(schedule_registry_list)
assert_eq "list on empty registry returns []" "[]" "$RESULT"
teardown

# ── Test 2: add entry then list returns it ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
RESULT=$(schedule_registry_list | jq length)
assert_eq "add then list has 1 entry" "1" "$RESULT"
ID=$(schedule_registry_list | jq -r '.[0].id')
assert_eq "added entry has correct id" "cekernel-cron-abc123" "$ID"
teardown

# ── Test 3: add multiple entries ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
schedule_registry_add "$SAMPLE_AT_ENTRY"
RESULT=$(schedule_registry_list | jq length)
assert_eq "add two entries, list has 2" "2" "$RESULT"
teardown

# ── Test 4: list --type cron filters correctly ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
schedule_registry_add "$SAMPLE_AT_ENTRY"
RESULT=$(schedule_registry_list --type cron | jq length)
assert_eq "list --type cron returns 1" "1" "$RESULT"
TYPE=$(schedule_registry_list --type cron | jq -r '.[0].type')
assert_eq "list --type cron returns cron entry" "cron" "$TYPE"
teardown

# ── Test 5: list --type at filters correctly ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
schedule_registry_add "$SAMPLE_AT_ENTRY"
RESULT=$(schedule_registry_list --type at | jq length)
assert_eq "list --type at returns 1" "1" "$RESULT"
TYPE=$(schedule_registry_list --type at | jq -r '.[0].type')
assert_eq "list --type at returns at entry" "at" "$TYPE"
teardown

# ── Test 6: get existing entry ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
RESULT=$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.id')
assert_eq "get returns correct entry" "cekernel-cron-abc123" "$RESULT"
teardown

# ── Test 7: get non-existing entry returns exit 1 ──
setup
if schedule_registry_get "nonexistent" >/dev/null 2>&1; then
  assert_eq "get nonexistent returns non-zero" "1" "0"
else
  assert_eq "get nonexistent returns non-zero" "1" "1"
fi
teardown

# ── Test 8: remove existing entry ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
schedule_registry_add "$SAMPLE_AT_ENTRY"
schedule_registry_remove "cekernel-cron-abc123"
RESULT=$(schedule_registry_list | jq length)
assert_eq "remove leaves 1 entry" "1" "$RESULT"
REMAINING=$(schedule_registry_list | jq -r '.[0].id')
assert_eq "remaining entry is the at entry" "cekernel-at-def456" "$REMAINING"
teardown

# ── Test 9: remove non-existing entry is idempotent ──
setup
schedule_registry_remove "nonexistent"
RESULT=$(schedule_registry_list | jq length)
assert_eq "remove nonexistent is idempotent" "0" "$RESULT"
teardown

# ── Test 10: update_status changes last_run_status ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
schedule_registry_update_status "cekernel-cron-abc123" "success"
STATUS=$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.last_run_status')
assert_eq "update_status sets success" "success" "$STATUS"
teardown

# ── Test 11: update_status changes last_run_at ──
setup
schedule_registry_add "$SAMPLE_ENTRY"
schedule_registry_update_status "cekernel-cron-abc123" "error"
RUN_AT=$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.last_run_at')
assert_match "update_status sets last_run_at to ISO timestamp" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$RUN_AT"
STATUS=$(schedule_registry_get "cekernel-cron-abc123" | jq -r '.last_run_status')
assert_eq "update_status sets error" "error" "$STATUS"
teardown

# ── Test 12: lock timeout on contended lock ──
setup
mkdir "${CEKERNEL_SCHEDULE_DIR}/schedules.json.lock"
if schedule_registry_add "$SAMPLE_ENTRY" 2>/dev/null; then
  assert_eq "add fails when lock is held" "fail" "success"
else
  assert_eq "add fails when lock is held" "1" "1"
fi
rmdir "${CEKERNEL_SCHEDULE_DIR}/schedules.json.lock"
teardown

report_results
