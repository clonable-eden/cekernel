#!/usr/bin/env bash
# test-transcript-locator.sh — Tests for transcript-locator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: transcript-locator"

# Test session
export CEKERNEL_SESSION_ID="test-transcript-locator-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

# ── Setup ──
TMPDIR_TEST=$(mktemp -d)
MOCK_CLAUDE_HOME="${TMPDIR_TEST}/claude-home"
MOCK_VAR_DIR="${TMPDIR_TEST}/var"

cleanup() {
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

# Source the transcript-locator helper
source "${CEKERNEL_DIR}/scripts/shared/transcript-locator.sh"

# ── Test 1: Worker transcript discovery — single file ──
WORKER_PROJECT="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo-.worktrees-issue-42-feat-add-widget"
mkdir -p "$WORKER_PROJECT"
touch "${WORKER_PROJECT}/session-abc123.jsonl"

RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME")
assert_eq "Worker transcript found for issue 42" "${WORKER_PROJECT}/session-abc123.jsonl" "$RESULT"

# ── Test 2: Worker transcript discovery — multiple files (resume) ──
touch "${WORKER_PROJECT}/session-def456.jsonl"

RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME" | sort)
EXPECTED=$(printf '%s\n%s' "${WORKER_PROJECT}/session-abc123.jsonl" "${WORKER_PROJECT}/session-def456.jsonl" | sort)
assert_eq "Multiple worker transcripts found (resume)" "$EXPECTED" "$RESULT"

# ── Test 3: Worker transcript discovery — no match ──
EXIT_CODE=0
RESULT=$(transcript_locate_worker 999 "$MOCK_CLAUDE_HOME" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Worker transcript not found returns empty" "" "$RESULT"
assert_eq "Worker transcript not found exit code 1" "1" "$EXIT_CODE"

# ── Test 4: Reviewer transcript shares same pattern as Worker ──
REVIEWER_PROJECT="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo-.worktrees-issue-42-feat-add-widget-reviewer"
mkdir -p "$REVIEWER_PROJECT"
touch "${REVIEWER_PROJECT}/session-review1.jsonl"

# Worker locate should also find reviewer transcripts (both contain issue number)
RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME" | wc -l | tr -d ' ')
assert_eq "Finds transcripts from both worker and reviewer worktrees" "3" "$RESULT"

# ── Test 5: Orchestrator transcript discovery ──
ORCH_SESSION_DIR="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/session-orch1/subagents"
mkdir -p "$ORCH_SESSION_DIR"
touch "${ORCH_SESSION_DIR}/agent-orch-001.jsonl"
touch "${ORCH_SESSION_DIR}/agent-orch-002.jsonl"

RESULT=$(transcript_locate_orchestrator "session-orch1" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | sort)
EXPECTED=$(printf '%s\n%s' "${ORCH_SESSION_DIR}/agent-orch-001.jsonl" "${ORCH_SESSION_DIR}/agent-orch-002.jsonl" | sort)
assert_eq "Orchestrator transcripts found via session ID" "$EXPECTED" "$RESULT"

# ── Test 6: Orchestrator transcript — session not found ──
EXIT_CODE=0
RESULT=$(transcript_locate_orchestrator "nonexistent-session" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Orchestrator transcript not found returns empty" "" "$RESULT"
assert_eq "Orchestrator transcript not found exit code 1" "1" "$EXIT_CODE"

# ── Test 7: transcript_locate_all combines worker + orchestrator ──
RESULT=$(transcript_locate_all 42 "session-orch1" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | wc -l | tr -d ' ')
assert_eq "transcript_locate_all returns all transcripts" "5" "$RESULT"

# ── Test 8: transcript_locate_all without orchestrator session ──
RESULT=$(transcript_locate_all 42 "" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "transcript_locate_all works without orchestrator session" "3" "$RESULT"

# ── Test 9: Non-.jsonl files are excluded ──
touch "${WORKER_PROJECT}/not-a-transcript.txt"
touch "${WORKER_PROJECT}/session.json"
RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME" | wc -l | tr -d ' ')
assert_eq "Non-.jsonl files excluded" "3" "$RESULT"

# ── Test 10: Error message on stderr for absent transcripts ──
ERR_OUTPUT=$(transcript_locate_worker 888 "$MOCK_CLAUDE_HOME" 2>&1 1>/dev/null || true)
assert_match "Error message on stderr for missing transcripts" "No.*transcript" "$ERR_OUTPUT"

# ── Test 11: Issue number must be numeric ──
EXIT_CODE=0
ERR_OUTPUT=$(transcript_locate_worker "abc" "$MOCK_CLAUDE_HOME" 2>&1 1>/dev/null) || EXIT_CODE=$?
assert_match "Non-numeric issue number produces error" "numeric" "$ERR_OUTPUT"
assert_eq "Non-numeric issue number returns exit code 1" "1" "$EXIT_CODE"

# ── Test 12: Orchestrator discovery via .spawned files (by issue number) ──
# Create mock .spawned files in session IPC directories
MOCK_SESSION="mock-session-orch1"
MOCK_IPC_SESSION="${MOCK_VAR_DIR}/ipc/${MOCK_SESSION}"
mkdir -p "$MOCK_IPC_SESSION"
touch "${MOCK_IPC_SESSION}/worker-42.spawned"

# Create orchestrator transcripts for this session
ORCH_SESSION_DIR2="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/${MOCK_SESSION}/subagents"
mkdir -p "$ORCH_SESSION_DIR2"
touch "${ORCH_SESSION_DIR2}/agent-orch-010.jsonl"

RESULT=$(transcript_locate_orchestrator_by_issue 42 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo")
assert_eq "Orchestrator found via .spawned file reverse lookup" "${ORCH_SESSION_DIR2}/agent-orch-010.jsonl" "$RESULT"

# ── Test 13: _by_issue — reviewer .spawned file also matches ──
MOCK_SESSION2="mock-session-orch2"
MOCK_IPC_SESSION2="${MOCK_VAR_DIR}/ipc/${MOCK_SESSION2}"
mkdir -p "$MOCK_IPC_SESSION2"
touch "${MOCK_IPC_SESSION2}/reviewer-42.spawned"

ORCH_SESSION_DIR3="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/${MOCK_SESSION2}/subagents"
mkdir -p "$ORCH_SESSION_DIR3"
touch "${ORCH_SESSION_DIR3}/agent-orch-020.jsonl"

# Should find transcripts from both sessions
RESULT=$(transcript_locate_orchestrator_by_issue 42 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | wc -l | tr -d ' ')
assert_eq "Finds orchestrator transcripts from multiple sessions via .spawned" "2" "$RESULT"

# ── Test 14: _by_issue — no .spawned files for issue ──
EXIT_CODE=0
RESULT=$(transcript_locate_orchestrator_by_issue 777 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Returns exit 1 when no .spawned files for issue" "1" "$EXIT_CODE"

# ── Test 15: _by_issue — .spawned file exists but no orchestrator transcripts ──
MOCK_SESSION3="mock-session-no-orch"
MOCK_IPC_SESSION3="${MOCK_VAR_DIR}/ipc/${MOCK_SESSION3}"
mkdir -p "$MOCK_IPC_SESSION3"
touch "${MOCK_IPC_SESSION3}/worker-99.spawned"

EXIT_CODE=0
RESULT=$(transcript_locate_orchestrator_by_issue 99 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Returns exit 1 when .spawned exists but no orchestrator transcripts" "1" "$EXIT_CODE"

# ── Test 16: transcript_locate_all uses _by_issue for orchestrator discovery ──
RESULT=$(transcript_locate_all 42 "" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" "$MOCK_VAR_DIR" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "transcript_locate_all uses _by_issue as fallback" "5" "$RESULT"

report_results
