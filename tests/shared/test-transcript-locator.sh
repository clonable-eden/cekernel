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

cleanup() {
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

# Source the transcript-locator helper (override CLAUDE_PROJECTS_DIR)
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

# ── Test 12: Orchestrator discovery via IPC-persisted session ID ──
# Persist a Claude Code session ID to the IPC dir, then use transcript_locate_orchestrator_by_ipc
ORIG_IPC_DIR="$CEKERNEL_IPC_DIR"
export CEKERNEL_IPC_DIR="${TMPDIR_TEST}/ipc"
mkdir -p "$CEKERNEL_IPC_DIR"

source "${CEKERNEL_DIR}/scripts/shared/claude-session-id.sh"
claude_session_id_persist "session-orch1"

RESULT=$(transcript_locate_orchestrator_by_ipc "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | sort)
EXPECTED=$(printf '%s\n%s' "${ORCH_SESSION_DIR}/agent-orch-001.jsonl" "${ORCH_SESSION_DIR}/agent-orch-002.jsonl" | sort)
assert_eq "Orchestrator found via IPC-persisted session ID" "$EXPECTED" "$RESULT"

# ── Test 13: Orchestrator via IPC — no persisted session ID ──
rm -f "${CEKERNEL_IPC_DIR}/claude-session-id"
EXIT_CODE=0
RESULT=$(transcript_locate_orchestrator_by_ipc "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Returns exit 1 when no persisted session ID" "1" "$EXIT_CODE"

# ── Test 14: transcript_locate_all uses IPC session ID when no explicit session given ──
claude_session_id_persist "session-orch1"
RESULT=$(transcript_locate_all 42 "" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "transcript_locate_all uses IPC session ID as fallback" "5" "$RESULT"

export CEKERNEL_IPC_DIR="$ORIG_IPC_DIR"

report_results
