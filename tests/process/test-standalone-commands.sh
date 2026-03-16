#!/usr/bin/env bash
# test-standalone-commands.sh — Tests for standalone process commands
#   worker-state-write.sh, create-checkpoint.sh, clear-resume-marker.sh
#
# These scripts are thin wrappers around shared library functions,
# allowing LLM agents (running in zsh) to call them without sourcing
# bash-specific scripts directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: standalone-commands"

# Test session
export CEKERNEL_SESSION_ID="test-standalone-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup ──
TMPDIR_TEST=$(mktemp -d)
MOCK_WORKTREE="${TMPDIR_TEST}/worktree"
mkdir -p "$MOCK_WORKTREE"

rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"

cleanup() {
  rm -rf "$CEKERNEL_IPC_DIR" "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

WORKER_STATE_WRITE="${CEKERNEL_DIR}/scripts/process/worker-state-write.sh"
CREATE_CHECKPOINT="${CEKERNEL_DIR}/scripts/process/create-checkpoint.sh"
CLEAR_RESUME_MARKER="${CEKERNEL_DIR}/scripts/process/clear-resume-marker.sh"

# ── worker-state-write.sh ──

# Test 1: worker-state-write.sh creates state file
bash "$WORKER_STATE_WRITE" 50 RUNNING "phase1:implement"
assert_file_exists "worker-state-write creates state file" "${CEKERNEL_IPC_DIR}/worker-50.state"

# Test 2: State file contains correct state
CONTENT=$(cat "${CEKERNEL_IPC_DIR}/worker-50.state")
assert_match "State file starts with RUNNING" '^RUNNING:' "$CONTENT"

# Test 3: State file contains detail
assert_match "State file contains detail" "phase1:implement" "$CONTENT"

# Test 4: worker-state-write.sh accepts all valid states
for STATE in NEW READY RUNNING WAITING SUSPENDED TERMINATED; do
  EXIT_CODE=0
  bash "$WORKER_STATE_WRITE" 51 "$STATE" 2>/dev/null || EXIT_CODE=$?
  assert_eq "worker-state-write accepts $STATE" "0" "$EXIT_CODE"
done

# Test 5: worker-state-write.sh rejects invalid state
EXIT_CODE=0
bash "$WORKER_STATE_WRITE" 50 INVALID 2>/dev/null || EXIT_CODE=$?
assert_eq "worker-state-write rejects INVALID state" "1" "$EXIT_CODE"

# Test 6: worker-state-write.sh missing issue number exits non-zero
EXIT_CODE=0
bash "$WORKER_STATE_WRITE" 2>/dev/null || EXIT_CODE=$?
assert_eq "worker-state-write missing issue number exits non-zero" "1" "$EXIT_CODE"

# Test 7: worker-state-write.sh missing state exits non-zero
EXIT_CODE=0
bash "$WORKER_STATE_WRITE" 50 2>/dev/null || EXIT_CODE=$?
assert_eq "worker-state-write missing state exits non-zero" "1" "$EXIT_CODE"

# ── create-checkpoint.sh ──

# Test 8: create-checkpoint.sh creates checkpoint file
bash "$CREATE_CHECKPOINT" "$MOCK_WORKTREE" "Phase 1 (Implementation)" "tests written" "implement files" "chose approach X"
assert_file_exists "create-checkpoint creates checkpoint file" "${MOCK_WORKTREE}/.cekernel-checkpoint.md"

# Test 9: Checkpoint file contains phase
CP_CONTENT=$(cat "${MOCK_WORKTREE}/.cekernel-checkpoint.md")
assert_match "Checkpoint file contains phase" "Phase 1" "$CP_CONTENT"

# Test 10: Checkpoint file contains completed
assert_match "Checkpoint file contains completed" "tests written" "$CP_CONTENT"

# Test 11: Checkpoint file contains next steps
assert_match "Checkpoint file contains next" "implement files" "$CP_CONTENT"

# Test 12: Checkpoint file contains decisions
assert_match "Checkpoint file contains decisions" "chose approach X" "$CP_CONTENT"

# Test 13: Checkpoint file has markdown header
assert_match "Checkpoint file has # Checkpoint header" "^# Checkpoint" "$CP_CONTENT"

# Test 14: create-checkpoint.sh missing worktree exits non-zero
EXIT_CODE=0
bash "$CREATE_CHECKPOINT" 2>/dev/null || EXIT_CODE=$?
assert_eq "create-checkpoint missing args exits non-zero" "1" "$EXIT_CODE"

# ── clear-resume-marker.sh ──

# Test 15: clear-resume-marker.sh removes ## Resume Reason section
MARKER_WORKTREE="${TMPDIR_TEST}/marker-worktree"
mkdir -p "$MARKER_WORKTREE"
cat > "${MARKER_WORKTREE}/.cekernel-task.md" <<'TASK_WITH_MARKER'
---
issue: 100
title: "test issue"
labels: [enhancement]
---

Issue body content here.

## Resume Reason: changes-requested

Review comments are on PR #50.
TASK_WITH_MARKER

bash "$CLEAR_RESUME_MARKER" "$MARKER_WORKTREE"
MARKER_CONTENT=$(cat "${MARKER_WORKTREE}/.cekernel-task.md")

if echo "$MARKER_CONTENT" | grep -q "## Resume Reason"; then
  echo "  FAIL: clear-resume-marker should remove ## Resume Reason section"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: clear-resume-marker removes ## Resume Reason section"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Test 16: Original content is preserved
assert_match "clear-resume-marker preserves original content" "Issue body content here" "$MARKER_CONTENT"

# Test 17: clear-resume-marker.sh is no-op when no marker
NOMARKER_WORKTREE="${TMPDIR_TEST}/nomarker-worktree"
mkdir -p "$NOMARKER_WORKTREE"
cat > "${NOMARKER_WORKTREE}/.cekernel-task.md" <<'TASK_NO_MARKER'
---
issue: 101
title: "test issue"
labels: []
---

Just a normal task file.
TASK_NO_MARKER

BEFORE=$(cat "${NOMARKER_WORKTREE}/.cekernel-task.md")
bash "$CLEAR_RESUME_MARKER" "$NOMARKER_WORKTREE"
AFTER=$(cat "${NOMARKER_WORKTREE}/.cekernel-task.md")
assert_eq "clear-resume-marker is no-op when no marker" "$BEFORE" "$AFTER"

# Test 18: clear-resume-marker.sh exits cleanly when task file does not exist
MISSING_WORKTREE="${TMPDIR_TEST}/missing-worktree"
mkdir -p "$MISSING_WORKTREE"
EXIT_CODE=0
bash "$CLEAR_RESUME_MARKER" "$MISSING_WORKTREE" 2>/dev/null || EXIT_CODE=$?
assert_eq "clear-resume-marker exits cleanly when no task file" "0" "$EXIT_CODE"

# Test 19: clear-resume-marker.sh missing worktree arg exits non-zero
EXIT_CODE=0
bash "$CLEAR_RESUME_MARKER" 2>/dev/null || EXIT_CODE=$?
assert_eq "clear-resume-marker missing worktree arg exits non-zero" "1" "$EXIT_CODE"

report_results
