#!/usr/bin/env bash
# test-claude-session-id.sh — Tests for claude-session-id.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: claude-session-id"

# Test session
export CEKERNEL_SESSION_ID="test-claude-session-id-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup ──
TMPDIR_TEST=$(mktemp -d)
MOCK_CLAUDE_HOME="${TMPDIR_TEST}/claude-home"

# Override IPC dir for test isolation
ORIG_IPC_DIR="$CEKERNEL_IPC_DIR"
export CEKERNEL_IPC_DIR="${TMPDIR_TEST}/ipc"
mkdir -p "$CEKERNEL_IPC_DIR"

cleanup() {
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
  export CEKERNEL_IPC_DIR="$ORIG_IPC_DIR"
}
trap cleanup EXIT

source "${CEKERNEL_DIR}/scripts/shared/claude-session-id.sh"

# ── Test 1: Discover session ID — finds most recent .jsonl ──
PROJECT_DIR="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo"
mkdir -p "$PROJECT_DIR"
# Create older session
touch "${PROJECT_DIR}/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
sleep 0.1
# Create newer session (this should be discovered)
touch "${PROJECT_DIR}/11111111-2222-3333-4444-555555555555.jsonl"

RESULT=$(claude_session_id_discover "/Users/test/git/repo" "$MOCK_CLAUDE_HOME")
assert_eq "Discovers most recent session ID" "11111111-2222-3333-4444-555555555555" "$RESULT"

# ── Test 2: Discover session ID — excludes subagent directories ──
mkdir -p "${PROJECT_DIR}/11111111-2222-3333-4444-555555555555/subagents"
touch "${PROJECT_DIR}/11111111-2222-3333-4444-555555555555/subagents/agent-001.jsonl"

RESULT=$(claude_session_id_discover "/Users/test/git/repo" "$MOCK_CLAUDE_HOME")
assert_eq "Discover excludes subagent .jsonl files" "11111111-2222-3333-4444-555555555555" "$RESULT"

# ── Test 3: Discover session ID — no project directory ──
EXIT_CODE=0
RESULT=$(claude_session_id_discover "/nonexistent/path" "$MOCK_CLAUDE_HOME" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Returns exit 1 when project dir not found" "1" "$EXIT_CODE"

# ── Test 4: Discover session ID — no .jsonl files ──
EMPTY_PROJECT="${MOCK_CLAUDE_HOME}/projects/-Users-test-empty-project"
mkdir -p "$EMPTY_PROJECT"
EXIT_CODE=0
RESULT=$(claude_session_id_discover "/Users/test/empty-project" "$MOCK_CLAUDE_HOME" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Returns exit 1 when no .jsonl files exist" "1" "$EXIT_CODE"

# ── Test 5: Persist session ID ──
claude_session_id_persist "abcd1234-5678-90ab-cdef-1234567890ab"
assert_file_exists "Session ID file created" "${CEKERNEL_IPC_DIR}/claude-session-id"

CONTENT=$(cat "${CEKERNEL_IPC_DIR}/claude-session-id")
assert_eq "Persisted session ID content" "abcd1234-5678-90ab-cdef-1234567890ab" "$CONTENT"

# ── Test 6: Persist session ID — requires CEKERNEL_IPC_DIR ──
EXIT_CODE=0
(unset CEKERNEL_IPC_DIR; claude_session_id_persist "test" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Persist fails without CEKERNEL_IPC_DIR" "1" "$EXIT_CODE"

# ── Test 7: Read session ID ──
RESULT=$(claude_session_id_read)
assert_eq "Read returns persisted session ID" "abcd1234-5678-90ab-cdef-1234567890ab" "$RESULT"

# ── Test 8: Read session ID — file does not exist ──
rm -f "${CEKERNEL_IPC_DIR}/claude-session-id"
EXIT_CODE=0
RESULT=$(claude_session_id_read 2>/dev/null) || EXIT_CODE=$?
assert_eq "Read returns exit 1 when file missing" "1" "$EXIT_CODE"

# ── Test 9: Read session ID — requires CEKERNEL_IPC_DIR ──
EXIT_CODE=0
(unset CEKERNEL_IPC_DIR; claude_session_id_read 2>/dev/null) || EXIT_CODE=$?
assert_eq "Read fails without CEKERNEL_IPC_DIR" "1" "$EXIT_CODE"

# ── Test 10: Project slug derivation ──
RESULT=$(claude_session_id_project_slug "/Users/alice/git/myrepo")
assert_eq "Project slug from path" "-Users-alice-git-myrepo" "$RESULT"

# ── Test 11: Persist overwrites existing value ──
claude_session_id_persist "first-value"
claude_session_id_persist "second-value"
RESULT=$(claude_session_id_read)
assert_eq "Persist overwrites existing value" "second-value" "$RESULT"

report_results
