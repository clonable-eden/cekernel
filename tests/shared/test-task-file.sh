#!/usr/bin/env bash
# test-task-file.sh — Tests for task-file.sh (local issue data extraction)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: task-file"

# Test session
export CEKERNEL_SESSION_ID="test-task-file-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup ──
TMPDIR_TEST=$(mktemp -d)
MOCK_WORKTREE="${TMPDIR_TEST}/worktree"
mkdir -p "$MOCK_WORKTREE"

cleanup() {
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

# ── Mock gh command ──
# Create a mock gh that returns predictable issue data (with comments)
MOCK_BIN="${TMPDIR_TEST}/bin"
mkdir -p "$MOCK_BIN"
cat > "${MOCK_BIN}/gh" << 'MOCK_GH'
#!/usr/bin/env bash
# Mock gh: return predictable issue data with comments
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  ISSUE_NUM="${3:-}"
  # Check for --json flag
  for arg in "$@"; do
    if [[ "$arg" == "title,body,labels,comments" ]]; then
      cat <<ENDJSON
{
  "title": "feat: add widget support",
  "body": "## Description\nAdd widget support to the system.\n\n## Requirements\n- Support widget A\n- Support widget B",
  "labels": [{"name": "enhancement"}, {"name": "priority:high"}],
  "comments": [
    {
      "author": {"login": "alice"},
      "createdAt": "2025-01-15T10:30:00Z",
      "body": "I think we should use approach A for this."
    },
    {
      "author": {"login": "bob"},
      "createdAt": "2025-01-16T14:00:00Z",
      "body": "Agreed. See ADR-0010 for details."
    }
  ]
}
ENDJSON
      exit 0
    fi
  done
fi
echo "mock gh: unexpected arguments: $*" >&2
exit 1
MOCK_GH
chmod +x "${MOCK_BIN}/gh"

# Prepend mock bin to PATH
export PATH="${MOCK_BIN}:${PATH}"

# Source the task-file helper
source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

# ── Test 1: create_task_file creates .cekernel-task.md ──
create_task_file "$MOCK_WORKTREE" 42
assert_file_exists "Task file created in worktree" "${MOCK_WORKTREE}/.cekernel-task.md"

# ── Test 2: Task file contains issue number ──
CONTENT=$(cat "${MOCK_WORKTREE}/.cekernel-task.md")
assert_match "Task file contains issue number" "issue: 42" "$CONTENT"

# ── Test 3: Task file contains title ──
assert_match "Task file contains title" "feat: add widget support" "$CONTENT"

# ── Test 4: Task file contains labels ──
assert_match "Task file contains labels" "enhancement" "$CONTENT"

# ── Test 5: Task file contains body ──
assert_match "Task file contains body content" "Add widget support" "$CONTENT"

# ── Test 5a: Task file contains Comments section ──
assert_match "Task file contains Comments heading" "## Comments" "$CONTENT"

# ── Test 5b: Task file contains comment author ──
assert_match "Task file contains first comment author" "alice" "$CONTENT"
assert_match "Task file contains second comment author" "bob" "$CONTENT"

# ── Test 5c: Task file contains comment timestamps ──
assert_match "Task file contains first comment date" "2025-01-15" "$CONTENT"
assert_match "Task file contains second comment date" "2025-01-16" "$CONTENT"

# ── Test 5d: Task file contains comment body ──
assert_match "Task file contains first comment body" "approach A" "$CONTENT"
assert_match "Task file contains second comment body" "ADR-0010" "$CONTENT"

# ── Test 6: task_file_path returns correct path ──
TASK_PATH=$(task_file_path "$MOCK_WORKTREE")
assert_eq "task_file_path returns correct path" "${MOCK_WORKTREE}/.cekernel-task.md" "$TASK_PATH"

# ── Test 7: task_file_exists returns 0 when file exists ──
if task_file_exists "$MOCK_WORKTREE"; then
  echo "  PASS: task_file_exists returns 0 when file exists"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: task_file_exists should return 0 when file exists"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: task_file_exists returns 1 when file does not exist ──
EMPTY_WORKTREE="${TMPDIR_TEST}/empty-worktree"
mkdir -p "$EMPTY_WORKTREE"
if task_file_exists "$EMPTY_WORKTREE"; then
  echo "  FAIL: task_file_exists should return 1 when file does not exist"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: task_file_exists returns 1 when file does not exist"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 9: create_task_file with empty body and no comments ──
# Update mock to return empty body with no comments
cat > "${MOCK_BIN}/gh" << 'MOCK_GH2'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  for arg in "$@"; do
    if [[ "$arg" == "title,body,labels,comments" ]]; then
      cat <<ENDJSON
{
  "title": "chore: empty body issue",
  "body": "",
  "labels": [],
  "comments": []
}
ENDJSON
      exit 0
    fi
  done
fi
echo "mock gh: unexpected arguments: $*" >&2
exit 1
MOCK_GH2
chmod +x "${MOCK_BIN}/gh"

EMPTY_BODY_WORKTREE="${TMPDIR_TEST}/empty-body-worktree"
mkdir -p "$EMPTY_BODY_WORKTREE"
create_task_file "$EMPTY_BODY_WORKTREE" 99
assert_file_exists "Task file created with empty body" "${EMPTY_BODY_WORKTREE}/.cekernel-task.md"
CONTENT_EMPTY=$(cat "${EMPTY_BODY_WORKTREE}/.cekernel-task.md")
assert_match "Empty body task file has title" "chore: empty body issue" "$CONTENT_EMPTY"
assert_match "Empty body task file has issue number" "issue: 99" "$CONTENT_EMPTY"

# ── Test 10: No Comments section when comments array is empty ──
if [[ "$CONTENT_EMPTY" =~ "## Comments" ]]; then
  echo "  FAIL: No Comments section when no comments exist"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: No Comments section when no comments exist"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

report_results
