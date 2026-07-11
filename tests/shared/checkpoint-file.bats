#!/usr/bin/env bats
# checkpoint-file.bats — bats-core tests for scripts/shared/checkpoint-file.sh
#
# Verifies checkpoint file create/read/exists/overwrite behavior
# for the suspend/resume context-swap mechanism.

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${CEKERNEL_DIR}/scripts/shared/checkpoint-file.sh"

  MOCK_WORKTREE="${BATS_TEST_TMPDIR}/worktree"
  mkdir -p "$MOCK_WORKTREE"
}

@test "create_checkpoint_file creates .cekernel-checkpoint.md" {
  create_checkpoint_file "$MOCK_WORKTREE" "Phase 1 (Implementation)" \
    "tests written, 2/5 files implemented" "implement remaining 3 files" "chose approach X because Y"
  assert_file_exists "checkpoint file created" "${MOCK_WORKTREE}/.cekernel-checkpoint.md"
}

@test "checkpoint file contains all fields" {
  create_checkpoint_file "$MOCK_WORKTREE" "Phase 1 (Implementation)" \
    "tests written" "implement files" "chose approach X"
  local content
  content=$(cat "${MOCK_WORKTREE}/.cekernel-checkpoint.md")
  assert_match "has header" "^# Checkpoint" "$content"
  assert_match "contains phase" "Phase 1" "$content"
  assert_match "contains completed" "tests written" "$content"
  assert_match "contains next" "implement files" "$content"
  assert_match "contains decisions" "chose approach X" "$content"
}

@test "checkpoint_file_path returns correct path" {
  local path
  path=$(checkpoint_file_path "$MOCK_WORKTREE")
  assert_eq "correct path" "${MOCK_WORKTREE}/.cekernel-checkpoint.md" "$path"
}

@test "checkpoint_file_exists returns 0 when file exists" {
  create_checkpoint_file "$MOCK_WORKTREE" "Phase 1" "" "" ""
  checkpoint_file_exists "$MOCK_WORKTREE"
}

@test "checkpoint_file_exists returns 1 when file does not exist" {
  local empty_wt="${BATS_TEST_TMPDIR}/empty-wt"
  mkdir -p "$empty_wt"
  run checkpoint_file_exists "$empty_wt"
  assert_eq "exit 1" "1" "$status"
}

@test "create_checkpoint_file with empty optional fields" {
  create_checkpoint_file "$MOCK_WORKTREE" "Phase 2 (PR)" "" "" ""
  assert_file_exists "checkpoint created" "${MOCK_WORKTREE}/.cekernel-checkpoint.md"
  local content
  content=$(cat "${MOCK_WORKTREE}/.cekernel-checkpoint.md")
  assert_match "has phase" "Phase 2" "$content"
}

@test "create_checkpoint_file overwrites existing checkpoint" {
  create_checkpoint_file "$MOCK_WORKTREE" "Phase 1" "some work" "" ""
  create_checkpoint_file "$MOCK_WORKTREE" "Phase 2 (PR)" "all files implemented" "create PR" "approach X confirmed"
  local content
  content=$(cat "${MOCK_WORKTREE}/.cekernel-checkpoint.md")
  assert_match "new phase" "Phase 2" "$content"
  assert_match "new completed" "all files implemented" "$content"
}
