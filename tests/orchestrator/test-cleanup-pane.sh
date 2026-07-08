#!/usr/bin/env bash
# test-cleanup-pane.sh — Tests that cleanup-worktree.sh kills Workers via backend
#
# ADR-0016 Phase 5 semantics: the handle is an opaque session token
# (stopped via `claude stop`); the attach pane lives in pane-{issue}.{type}
# and its window is closed on cleanup. WezTerm and claude are mocked as
# PATH shims; kill-pane and stop calls are recorded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: cleanup-pane"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-cleanup-pane-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
source "${CEKERNEL_DIR}/scripts/shared/claude-json-helper.sh"

SESSION_TOKEN="aaaa1111-2222-4333-8444-555566667777"

# ── Create temporary Git repository for testing ──
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP" "$CEKERNEL_IPC_DIR" 2>/dev/null || true' EXIT

FAKE_REPO="${TEST_TMP}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "initial" --quiet

# Temporary ~/.claude.json for testing
FAKE_CLAUDE_JSON="${TEST_TMP}/claude.json"
export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"

# ── PATH shims: record wezterm and claude calls ──
WEZTERM_LOG="${TEST_TMP}/wezterm-calls.log"
CLAUDE_LOG="${TEST_TMP}/claude-calls.log"
MOCK_BIN="${TEST_TMP}/mock-bin"
mkdir -p "$MOCK_BIN"
export PATH="${MOCK_BIN}:${PATH}"

cat > "${MOCK_BIN}/claude" <<MOCK_SCRIPT
#!/usr/bin/env bash
echo "claude \$*" >> "${CLAUDE_LOG}"
MOCK_SCRIPT
chmod +x "${MOCK_BIN}/claude"

# setup_wezterm_mock [list-json-file]
# Records all calls; `cli list --format json` replays the given file ([] default).
setup_wezterm_mock() {
  local json_file="${1:-}"
  cat > "${MOCK_BIN}/wezterm" <<MOCK_SCRIPT
#!/usr/bin/env bash
echo "wezterm \$*" >> "${WEZTERM_LOG}"
if [[ "\${1:-}" == "cli" && "\${2:-}" == "list" ]]; then
  if [[ -n "${json_file}" ]]; then cat "${json_file}"; else echo "[]"; fi
fi
MOCK_SCRIPT
  chmod +x "${MOCK_BIN}/wezterm"
}

setup_worktree() {
  local issue="$1"
  local repo="$2"
  local branch="issue/${issue}-test-pane"
  local worktree="${repo}/.worktrees/${branch}"

  mkdir -p "${repo}/.worktrees"
  git -C "$repo" worktree add -b "$branch" "$worktree" HEAD --quiet
  echo "$worktree"
}

# ── Test 1: cleanup without --force → session stopped, pane killed ──
> "$WEZTERM_LOG"
> "$CLAUDE_LOG"
setup_wezterm_mock

ISSUE="200"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")

mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
# Phase 5: handle = opaque session token; pane = visualization detail
echo "$SESSION_TOKEN" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
echo "42" > "${CEKERNEL_IPC_DIR}/pane-${ISSUE}.worker"

cd "$FAKE_REPO"
CEKERNEL_BACKEND=wezterm bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" "$ISSUE" 2>/dev/null

if grep -q "stop ${SESSION_TOKEN}" "$CLAUDE_LOG" 2>/dev/null; then
  echo "  PASS: Session stopped via claude stop"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Session NOT stopped"
  echo "    claude calls: $(cat "$CLAUDE_LOG" 2>/dev/null || echo '(none)')"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

if grep -q "kill-pane.*42" "$WEZTERM_LOG" 2>/dev/null; then
  echo "  PASS: Pane killed without --force"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Pane NOT killed without --force"
  echo "    wezterm calls: $(cat "$WEZTERM_LOG" 2>/dev/null || echo '(none)')"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

assert_not_exists "Handle file removed after cleanup" "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
assert_not_exists "Pane file removed after cleanup" "${CEKERNEL_IPC_DIR}/pane-${ISSUE}.worker"

# ── Test 2: cleanup with --force → session stopped, pane killed ──
rm -rf "$CEKERNEL_IPC_DIR"
> "$WEZTERM_LOG"
> "$CLAUDE_LOG"

ISSUE="201"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")

mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
echo "$SESSION_TOKEN" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
echo "99" > "${CEKERNEL_IPC_DIR}/pane-${ISSUE}.worker"

CEKERNEL_BACKEND=wezterm bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" --force "$ISSUE" 2>/dev/null

if grep -q "kill-pane.*99" "$WEZTERM_LOG" 2>/dev/null; then
  echo "  PASS: Pane killed with --force"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Pane NOT killed with --force"
  echo "    wezterm calls: $(cat "$WEZTERM_LOG" 2>/dev/null || echo '(none)')"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

assert_not_exists "Handle file removed after --force cleanup" "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"

# ── Test 3: No handle/pane file → skips without error ──
rm -rf "$CEKERNEL_IPC_DIR"
> "$WEZTERM_LOG"
> "$CLAUDE_LOG"

ISSUE="202"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")

mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
# Do not create handle or pane files

CEKERNEL_BACKEND=wezterm bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" "$ISSUE" 2>/dev/null
RESULT=$?

assert_eq "Cleanup succeeds without handle file" "0" "$RESULT"

# wezterm kill-pane should not be called
if grep -q "kill-pane" "$WEZTERM_LOG" 2>/dev/null; then
  echo "  FAIL: kill-pane called despite no pane file"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: No kill-pane call when no pane file"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 4: All panes in same window are killed ──
rm -rf "$CEKERNEL_IPC_DIR"
> "$WEZTERM_LOG"
> "$CLAUDE_LOG"

# Mock data for wezterm cli list --format json
PANE_LIST_JSON="${TEST_TMP}/pane-list.json"
cat > "$PANE_LIST_JSON" <<'JSONEOF'
[
  {"window_id": 5, "tab_id": 10, "pane_id": 42, "workspace": "default", "title": "claude", "cwd": "/tmp"},
  {"window_id": 5, "tab_id": 10, "pane_id": 43, "workspace": "default", "title": "terminal", "cwd": "/tmp"},
  {"window_id": 5, "tab_id": 10, "pane_id": 44, "workspace": "default", "title": "watch", "cwd": "/tmp"},
  {"window_id": 99, "tab_id": 20, "pane_id": 100, "workspace": "other", "title": "other", "cwd": "/tmp"}
]
JSONEOF

setup_wezterm_mock "$PANE_LIST_JSON"

ISSUE="203"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")

mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
echo "$SESSION_TOKEN" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
echo "42" > "${CEKERNEL_IPC_DIR}/pane-${ISSUE}.worker"

cd "$FAKE_REPO"
CEKERNEL_BACKEND=wezterm bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" "$ISSUE" 2>/dev/null

# All panes in same window (42, 43, 44) should be killed
for pane in 42 43 44; do
  if grep -q "kill-pane.*--pane-id ${pane}" "$WEZTERM_LOG" 2>/dev/null; then
    echo "  PASS: Pane ${pane} killed"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "  FAIL: Pane ${pane} NOT killed"
    echo "    wezterm calls: $(cat "$WEZTERM_LOG" 2>/dev/null || echo '(none)')"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
done

# Pane 100 from different window should NOT be killed
if grep -q "kill-pane.*--pane-id 100" "$WEZTERM_LOG" 2>/dev/null; then
  echo "  FAIL: Pane 100 from different window was killed"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: Pane 100 from different window NOT killed"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 5: cli list fails → only main pane killed (fallback) ──
rm -rf "$CEKERNEL_IPC_DIR"
> "$WEZTERM_LOG"
> "$CLAUDE_LOG"

setup_wezterm_mock  # cli list replies []

ISSUE="204"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")

mkdir -p "$CEKERNEL_IPC_DIR"
mkfifo "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
echo "$SESSION_TOKEN" > "${CEKERNEL_IPC_DIR}/handle-${ISSUE}.worker"
echo "55" > "${CEKERNEL_IPC_DIR}/pane-${ISSUE}.worker"

cd "$FAKE_REPO"
CEKERNEL_BACKEND=wezterm bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" "$ISSUE" 2>/dev/null

# Main pane should be killed
if grep -q "kill-pane.*--pane-id 55" "$WEZTERM_LOG" 2>/dev/null; then
  echo "  PASS: Main pane 55 killed as fallback"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: Main pane 55 NOT killed as fallback"
  echo "    wezterm calls: $(cat "$WEZTERM_LOG" 2>/dev/null || echo '(none)')"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Only 1 kill-pane call
KILL_COUNT=$(grep -c "kill-pane" "$WEZTERM_LOG" 2>/dev/null || echo "0")
assert_eq "Fallback: only 1 kill-pane call" "1" "$KILL_COUNT"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
