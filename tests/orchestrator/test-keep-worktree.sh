#!/usr/bin/env bash
# test-keep-worktree.sh — Tests CEKERNEL_KEEP_WORKTREE behavior of cleanup-worktree.sh
#
# CEKERNEL_KEEP_WORKTREE=true preserves the worktree and local branch while
# still cleaning up IPC resources. --force always removes the worktree
# regardless of CEKERNEL_KEEP_WORKTREE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: keep-worktree"

# ── Test session ──
export CEKERNEL_SESSION_ID="test-keep-worktree-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"

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

# ── wezterm mock (no-op, records nothing needed here) ──
MOCK_BIN="${TEST_TMP}/mock-bin"
mkdir -p "$MOCK_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "${MOCK_BIN}/wezterm"
chmod +x "${MOCK_BIN}/wezterm"
export PATH="${MOCK_BIN}:${PATH}"

setup_worktree() {
  local issue="$1"
  local repo="$2"
  local branch="issue/${issue}-keep-test"
  local worktree="${repo}/.worktrees/${branch}"

  mkdir -p "${repo}/.worktrees"
  git -C "$repo" worktree add -b "$branch" "$worktree" HEAD --quiet
  echo "$worktree"
}

setup_ipc() {
  local issue="$1"
  mkdir -p "$CEKERNEL_IPC_DIR"
  mkfifo "${CEKERNEL_IPC_DIR}/worker-${issue}"
  echo "RUNNING" > "${CEKERNEL_IPC_DIR}/worker-${issue}.state"
}

cd "$FAKE_REPO"

# ── Test 1: CEKERNEL_KEEP_WORKTREE=true → worktree and branch preserved, IPC cleaned ──
ISSUE="300"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")
setup_ipc "$ISSUE"

CEKERNEL_KEEP_WORKTREE=true CEKERNEL_BACKEND=wezterm \
  bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" "$ISSUE" 2>/dev/null
RESULT=$?

assert_eq "keep=true: cleanup exits 0" "0" "$RESULT"
assert_dir_exists "keep=true: worktree preserved" "$WORKTREE"

if git -C "$FAKE_REPO" rev-parse --verify --quiet "issue/${ISSUE}-keep-test" >/dev/null; then
  echo "  PASS: keep=true: local branch preserved"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: keep=true: local branch was deleted"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

assert_not_exists "keep=true: FIFO removed" "${CEKERNEL_IPC_DIR}/worker-${ISSUE}"
assert_not_exists "keep=true: state file removed" "${CEKERNEL_IPC_DIR}/worker-${ISSUE}.state"

# ── Test 2: default (unset) → worktree and branch removed (regression) ──
rm -rf "$CEKERNEL_IPC_DIR"
git -C "$FAKE_REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
git -C "$FAKE_REPO" branch -D "issue/${ISSUE}-keep-test" >/dev/null 2>&1 || true

ISSUE="301"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")
setup_ipc "$ISSUE"

CEKERNEL_BACKEND=wezterm \
  bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" "$ISSUE" 2>/dev/null

assert_not_exists "default: worktree removed" "$WORKTREE"

if git -C "$FAKE_REPO" rev-parse --verify --quiet "issue/${ISSUE}-keep-test" >/dev/null; then
  echo "  FAIL: default: local branch NOT deleted"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: default: local branch deleted"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 3: keep=true + --force → worktree removed (force overrides keep) ──
rm -rf "$CEKERNEL_IPC_DIR"

ISSUE="302"
WORKTREE=$(setup_worktree "$ISSUE" "$FAKE_REPO")
setup_ipc "$ISSUE"

CEKERNEL_KEEP_WORKTREE=true CEKERNEL_BACKEND=wezterm \
  bash "${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh" --force "$ISSUE" 2>/dev/null

assert_not_exists "keep=true + --force: worktree removed" "$WORKTREE"

# ── Cleanup ──
rm -rf "$CEKERNEL_IPC_DIR"

report_results
