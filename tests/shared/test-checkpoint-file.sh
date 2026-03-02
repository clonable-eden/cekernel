#!/usr/bin/env bash
# test-checkpoint-file.sh — Tests for checkpoint-file.sh (suspend/resume checkpoint management)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: checkpoint-file"

# Test session
export CEKERNEL_SESSION_ID="test-checkpoint-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup ──
TMPDIR_TEST=$(mktemp -d)
MOCK_WORKTREE="${TMPDIR_TEST}/worktree"
mkdir -p "$MOCK_WORKTREE"

cleanup() {
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

# Source the checkpoint-file helper
source "${CEKERNEL_DIR}/scripts/shared/checkpoint-file.sh"

# ── Test 1: create_checkpoint_file creates .cekernel-checkpoint.md ──
create_checkpoint_file "$MOCK_WORKTREE" "Phase 1 (Implementation)" "tests written, 2/5 files implemented" "implement remaining 3 files" "chose approach X because Y"
assert_file_exists "Checkpoint file created in worktree" "${MOCK_WORKTREE}/.cekernel-checkpoint.md"

# ── Test 2: Checkpoint file contains phase ──
CONTENT=$(cat "${MOCK_WORKTREE}/.cekernel-checkpoint.md")
assert_match "Checkpoint file contains phase" "Phase 1" "$CONTENT"

# ── Test 3: Checkpoint file contains completed work ──
assert_match "Checkpoint file contains completed" "tests written, 2/5 files implemented" "$CONTENT"

# ── Test 4: Checkpoint file contains next steps ──
assert_match "Checkpoint file contains next" "implement remaining 3 files" "$CONTENT"

# ── Test 5: Checkpoint file contains key decisions ──
assert_match "Checkpoint file contains decisions" "chose approach X because Y" "$CONTENT"

# ── Test 6: Checkpoint file has markdown header ──
assert_match "Checkpoint file has header" "^# Checkpoint" "$CONTENT"

# ── Test 7: checkpoint_file_path returns correct path ──
CP_PATH=$(checkpoint_file_path "$MOCK_WORKTREE")
assert_eq "checkpoint_file_path returns correct path" "${MOCK_WORKTREE}/.cekernel-checkpoint.md" "$CP_PATH"

# ── Test 8: checkpoint_file_exists returns 0 when file exists ──
if checkpoint_file_exists "$MOCK_WORKTREE"; then
  echo "  PASS: checkpoint_file_exists returns 0 when file exists"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: checkpoint_file_exists should return 0 when file exists"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: checkpoint_file_exists returns 1 when file does not exist ──
EMPTY_WORKTREE="${TMPDIR_TEST}/empty-worktree"
mkdir -p "$EMPTY_WORKTREE"
if checkpoint_file_exists "$EMPTY_WORKTREE"; then
  echo "  FAIL: checkpoint_file_exists should return 1 when file does not exist"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: checkpoint_file_exists returns 1 when file does not exist"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 10: read_checkpoint_file returns checkpoint content as JSON ──
JSON=$(read_checkpoint_file "$MOCK_WORKTREE")
assert_match "JSON contains phase" '"phase"' "$JSON"
assert_match "JSON contains completed" '"completed"' "$JSON"
assert_match "JSON contains next" '"next"' "$JSON"
assert_match "JSON contains decisions" '"decisions"' "$JSON"

# ── Test 11: read_checkpoint_file from non-existent file returns empty JSON ──
JSON_EMPTY=$(read_checkpoint_file "$EMPTY_WORKTREE")
assert_match "Empty checkpoint returns exists:false" '"exists":false' "$JSON_EMPTY"

# ── Test 12: create_checkpoint_file with empty optional fields ──
EMPTY_FIELDS_WORKTREE="${TMPDIR_TEST}/empty-fields-worktree"
mkdir -p "$EMPTY_FIELDS_WORKTREE"
create_checkpoint_file "$EMPTY_FIELDS_WORKTREE" "Phase 2 (PR)" "" "" ""
assert_file_exists "Checkpoint with empty fields created" "${EMPTY_FIELDS_WORKTREE}/.cekernel-checkpoint.md"
CONTENT_EMPTY=$(cat "${EMPTY_FIELDS_WORKTREE}/.cekernel-checkpoint.md")
assert_match "Empty fields checkpoint has phase" "Phase 2" "$CONTENT_EMPTY"

# ── Test 13: create_checkpoint_file overwrites existing checkpoint ──
create_checkpoint_file "$MOCK_WORKTREE" "Phase 2 (PR)" "all files implemented" "create PR" "approach X confirmed"
CONTENT_NEW=$(cat "${MOCK_WORKTREE}/.cekernel-checkpoint.md")
assert_match "Overwritten checkpoint has new phase" "Phase 2" "$CONTENT_NEW"
assert_match "Overwritten checkpoint has new completed" "all files implemented" "$CONTENT_NEW"

report_results
