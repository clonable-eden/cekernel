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
WORKER_PROJECT="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo--worktrees-issue-42-feat-add-widget"
mkdir -p "$WORKER_PROJECT"
touch "${WORKER_PROJECT}/session-abc123.jsonl"

RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME") || true
assert_eq "Worker transcript found for issue 42" "${WORKER_PROJECT}/session-abc123.jsonl" "$RESULT"

# ── Test 2: Worker transcript discovery — multiple files (resume) ──
touch "${WORKER_PROJECT}/session-def456.jsonl"

RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME" | sort) || true
EXPECTED=$(printf '%s\n%s' "${WORKER_PROJECT}/session-abc123.jsonl" "${WORKER_PROJECT}/session-def456.jsonl" | sort)
assert_eq "Multiple worker transcripts found (resume)" "$EXPECTED" "$RESULT"

# ── Test 3: Worker transcript discovery — no match ──
EXIT_CODE=0
RESULT=$(transcript_locate_worker 999 "$MOCK_CLAUDE_HOME" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Worker transcript not found returns empty" "" "$RESULT"
assert_eq "Worker transcript not found exit code 1" "1" "$EXIT_CODE"

# ── Test 4: Reviewer transcript shares same pattern as Worker ──
REVIEWER_PROJECT="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo--worktrees-issue-42-feat-add-widget-reviewer"
mkdir -p "$REVIEWER_PROJECT"
touch "${REVIEWER_PROJECT}/session-review1.jsonl"

# Worker locate should also find reviewer transcripts (both contain issue number)
RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME" | wc -l | tr -d ' ') || true
assert_eq "Finds transcripts from both worker and reviewer worktrees" "3" "$RESULT"

# ── Test 5: Orchestrator transcript discovery ──
ORCH_SESSION_DIR="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/session-orch1/subagents"
mkdir -p "$ORCH_SESSION_DIR"
touch "${ORCH_SESSION_DIR}/agent-orch-001.jsonl"
touch "${ORCH_SESSION_DIR}/agent-orch-002.jsonl"

RESULT=$(transcript_locate_orchestrator "session-orch1" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | sort) || true
EXPECTED=$(printf '%s\n%s' "${ORCH_SESSION_DIR}/agent-orch-001.jsonl" "${ORCH_SESSION_DIR}/agent-orch-002.jsonl" | sort)
assert_eq "Orchestrator transcripts found via session ID" "$EXPECTED" "$RESULT"

# ── Test 6: Orchestrator transcript — session not found ──
EXIT_CODE=0
RESULT=$(transcript_locate_orchestrator "nonexistent-session" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null) || EXIT_CODE=$?
assert_eq "Orchestrator transcript not found returns empty" "" "$RESULT"
assert_eq "Orchestrator transcript not found exit code 1" "1" "$EXIT_CODE"

# ── Test 7: transcript_locate_all combines worker + orchestrator ──
RESULT=$(transcript_locate_all 42 "session-orch1" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | wc -l | tr -d ' ') || true
assert_eq "transcript_locate_all returns all transcripts" "5" "$RESULT"

# ── Test 8: transcript_locate_all without orchestrator session ──
RESULT=$(transcript_locate_all 42 "" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null | wc -l | tr -d ' ') || true
assert_eq "transcript_locate_all works without orchestrator session" "3" "$RESULT"

# ── Test 9: Non-.jsonl files are excluded ──
touch "${WORKER_PROJECT}/not-a-transcript.txt"
touch "${WORKER_PROJECT}/session.json"
RESULT=$(transcript_locate_worker 42 "$MOCK_CLAUDE_HOME" | wc -l | tr -d ' ') || true
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

RESULT=$(transcript_locate_orchestrator_by_issue 42 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo") || true
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
RESULT=$(transcript_locate_orchestrator_by_issue 42 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | wc -l | tr -d ' ') || true
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
RESULT=$(transcript_locate_all 42 "" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" "$MOCK_VAR_DIR" 2>/dev/null | wc -l | tr -d ' ') || true
assert_eq "transcript_locate_all uses _by_issue as fallback" "5" "$RESULT"

# ══════════════════════════════════════════════════════════════════════════════
# Tests for claude -p model (Orchestrator as independent process)
# ══════════════════════════════════════════════════════════════════════════════

# ── Test 17: transcript_locate_orchestrator finds direct JSONL (claude -p model) ──
DIRECT_SESSION="direct-orch-uuid-1"
DIRECT_JSONL="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/${DIRECT_SESSION}.jsonl"
echo '{"type":"agent-setting","agentSetting":"orchestrator","sessionId":"direct-orch-uuid-1"}' > "$DIRECT_JSONL"

RESULT=$(transcript_locate_orchestrator "$DIRECT_SESSION" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo") || true
assert_eq "Direct JSONL found for orchestrator (claude -p)" "$DIRECT_JSONL" "$RESULT"

# ── Test 18: transcript_locate_orchestrator finds both direct and subagent ──
BOTH_SESSION="both-orch-session"
BOTH_SUBDIR="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/${BOTH_SESSION}/subagents"
mkdir -p "$BOTH_SUBDIR"
touch "${BOTH_SUBDIR}/agent-both-001.jsonl"
touch "${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/${BOTH_SESSION}.jsonl"

RESULT=$(transcript_locate_orchestrator "$BOTH_SESSION" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" | wc -l | tr -d ' ') || true
assert_eq "Finds both direct and subagent transcripts for same session" "2" "$RESULT"

# ── Test 19: _by_issue with orchestrator.spawned + agentSetting scan ──
# Create new session with orchestrator.spawned marker
CLAUDE_P_SESSION="mock-session-claude-p"
CLAUDE_P_IPC="${MOCK_VAR_DIR}/ipc/${CLAUDE_P_SESSION}"
mkdir -p "$CLAUDE_P_IPC"
date +%s > "${CLAUDE_P_IPC}/worker-100.spawned"
date +%s > "${CLAUDE_P_IPC}/orchestrator.spawned"

# Create orchestrator JSONL with agentSetting in main project dir
ORCH_CP_JSONL="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/orch-claude-p-uuid.jsonl"
echo '{"type":"agent-setting","agentSetting":"orchestrator","sessionId":"orch-claude-p-uuid"}' > "$ORCH_CP_JSONL"

# Worker project dir for issue 100 (needed for main slug derivation)
WORKER_100="${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo--worktrees-issue-100-test-feature"
mkdir -p "$WORKER_100"

RESULT=$(transcript_locate_orchestrator_by_issue 100 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null) || true
assert_match "Finds orchestrator JSONL via agentSetting scan" "orch-claude-p-uuid" "$RESULT"

# ── Test 20: agentSetting scan excludes non-orchestrator JSONL ──
# Worker JSONL should be excluded; only orchestrator JSONLs are returned.
# direct-orch-uuid-1.jsonl (test 17) + orch-claude-p-uuid.jsonl (test 19) = 2
echo '{"type":"agent-setting","agentSetting":"worker","sessionId":"worker-session-1"}' > "${MOCK_CLAUDE_HOME}/projects/-Users-test-git-repo/worker-session-1.jsonl"

RESULT=$(transcript_locate_orchestrator_by_issue 100 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null | wc -l | tr -d ' ') || true
assert_eq "agentSetting scan excludes non-orchestrator JSONL" "2" "$RESULT"

# ── Test 21: _by_issue without project_slug derives main slug from worker dirs ──
RESULT=$(transcript_locate_orchestrator_by_issue 100 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "" 2>/dev/null) || true
assert_match "Derives main project slug and finds orchestrator" "orch-claude-p-uuid" "$RESULT"

# ── Test 22: _by_issue prefers subagent path (backward compat) ──
# For issue 42, sessions mock-session-orch1 and mock-session-orch2 have subagent transcripts
# The function should find those via subagent path, not fall through to agentSetting scan
RESULT=$(transcript_locate_orchestrator_by_issue 42 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null | wc -l | tr -d ' ') || true
assert_eq "Backward compat: subagent path still works for issue 42" "2" "$RESULT"

# ── Test 23: orchestrator.spawned absent — only subagent path used ──
# For issue 42, sessions don't have orchestrator.spawned, so only subagent path is searched
# (same result as test 22 — confirms no agentSetting scan runs)
NO_ORCH_SESSION="mock-session-no-orch-spawned"
NO_ORCH_IPC="${MOCK_VAR_DIR}/ipc/${NO_ORCH_SESSION}"
mkdir -p "$NO_ORCH_IPC"
date +%s > "${NO_ORCH_IPC}/worker-200.spawned"
# No orchestrator.spawned, and no subagent transcripts for this session
EXIT_CODE=0
RESULT=$(transcript_locate_orchestrator_by_issue 200 "$MOCK_VAR_DIR" "$MOCK_CLAUDE_HOME" "-Users-test-git-repo" 2>/dev/null) || EXIT_CODE=$?
assert_eq "No orchestrator.spawned and no subagent = exit 1" "1" "$EXIT_CODE"

report_results
