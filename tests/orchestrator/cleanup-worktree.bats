#!/usr/bin/env bats
# cleanup-worktree.bats — bats-core tests for scripts/orchestrator/cleanup-worktree.sh
#
# CEKERNEL_KEEP_WORKTREE=true preserves the worktree and local branch while
# still cleaning up IPC resources (FIFOs are removed so concurrency slots do
# not leak). --force always removes the worktree regardless of
# CEKERNEL_KEEP_WORKTREE (zombie recovery must free the worktree).

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CLEANUP_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/cleanup-worktree.sh"

  # Test session (isolated IPC dir)
  export CEKERNEL_SESSION_ID="test-cleanup-worktree-00000001"
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"

  TEST_TMP="$(mktemp -d)"

  # Temporary Git repository for testing
  FAKE_REPO="${TEST_TMP}/repo"
  mkdir -p "$FAKE_REPO"
  git -C "$FAKE_REPO" init --quiet
  git -C "$FAKE_REPO" -c user.name="test" -c user.email="test@test" \
    commit --allow-empty -m "initial" --quiet

  # Temporary ~/.claude.json for testing
  export CLAUDE_JSON="${TEST_TMP}/claude.json"
  export LOCK_DIR="${CLAUDE_JSON}.lock"

  # wezterm mock (no-op)
  MOCK_BIN="${TEST_TMP}/mock-bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${MOCK_BIN}/wezterm"
  chmod +x "${MOCK_BIN}/wezterm"
  export PATH="${MOCK_BIN}:${PATH}"
  export CEKERNEL_BACKEND=wezterm

  cd "$FAKE_REPO"
}

teardown() {
  cd /
  rm -rf "$TEST_TMP" "$CEKERNEL_IPC_DIR"
}

# Create a worktree for the given issue number; echoes the worktree path.
setup_worktree() {
  local issue="$1"
  local branch="issue/${issue}-keep-test"
  local worktree="${FAKE_REPO}/.worktrees/${branch}"

  mkdir -p "${FAKE_REPO}/.worktrees"
  git -C "$FAKE_REPO" worktree add -b "$branch" "$worktree" HEAD --quiet
  echo "$worktree"
}

# Create session-scoped IPC resources (FIFO + state file) for the issue.
setup_ipc() {
  local issue="$1"
  mkdir -p "$CEKERNEL_IPC_DIR"
  mkfifo "${CEKERNEL_IPC_DIR}/worker-${issue}"
  echo "RUNNING" > "${CEKERNEL_IPC_DIR}/worker-${issue}.state"
}

@test "CEKERNEL_KEEP_WORKTREE=true preserves worktree and branch, cleans IPC" {
  local issue="300"
  local worktree
  worktree=$(setup_worktree "$issue")
  setup_ipc "$issue"

  export CEKERNEL_KEEP_WORKTREE=true
  run bash "$CLEANUP_SCRIPT" "$issue"

  assert_eq "keep=true: cleanup exits 0" "0" "$status"
  assert_dir_exists "keep=true: worktree preserved" "$worktree"

  run git -C "$FAKE_REPO" rev-parse --verify --quiet "issue/${issue}-keep-test"
  assert_eq "keep=true: local branch preserved" "0" "$status"

  assert_not_exists "keep=true: FIFO removed" "${CEKERNEL_IPC_DIR}/worker-${issue}"
  assert_not_exists "keep=true: state file removed" "${CEKERNEL_IPC_DIR}/worker-${issue}.state"
}

@test "default (unset) removes worktree and branch (regression)" {
  local issue="301"
  local worktree
  worktree=$(setup_worktree "$issue")
  setup_ipc "$issue"

  run bash "$CLEANUP_SCRIPT" "$issue"

  assert_eq "default: cleanup exits 0" "0" "$status"
  assert_not_exists "default: worktree removed" "$worktree"

  run git -C "$FAKE_REPO" rev-parse --verify --quiet "issue/${issue}-keep-test"
  assert_eq "default: local branch deleted" "1" "$status"
}

@test "keep=true + --force removes worktree (force overrides keep)" {
  local issue="302"
  local worktree
  worktree=$(setup_worktree "$issue")
  setup_ipc "$issue"

  export CEKERNEL_KEEP_WORKTREE=true
  run bash "$CLEANUP_SCRIPT" --force "$issue"

  assert_eq "keep=true + --force: cleanup exits 0" "0" "$status"
  assert_not_exists "keep=true + --force: worktree removed" "$worktree"
}

# ── ADR-0020 Phase 1: reaper log retention + exit event on non-TERMINATED reap ──

@test "cleanup retains the lifecycle log (no longer deletes it)" {
  local issue="303"
  local worktree
  worktree=$(setup_worktree "$issue")
  setup_ipc "$issue"

  # Create log file
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
  echo "[2026-07-09T00:00:00Z] SPAWN issue=#${issue}" > "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log"

  run bash "$CLEANUP_SCRIPT" "$issue"
  assert_eq "cleanup exits 0" "0" "$status"

  # ADR-0020: log is RETAINED (no longer deleted)
  assert_file_exists "log file retained" "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log"
}

@test "cleanup appends exit event to log when reaping non-TERMINATED state" {
  local issue="304"
  local worktree
  worktree=$(setup_worktree "$issue")
  setup_ipc "$issue"

  # Set state to RUNNING (non-TERMINATED)
  echo "RUNNING:2026-07-09T00:00:00Z:phase1:implement" > "${CEKERNEL_IPC_DIR}/worker-${issue}.state"

  # Create log file
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
  echo "[2026-07-09T00:00:00Z] SPAWN issue=#${issue}" > "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log"

  run bash "$CLEANUP_SCRIPT" "$issue"
  assert_eq "cleanup exits 0" "0" "$status"

  # ADR-0020: exit event appended for non-TERMINATED reap
  assert_file_exists "log file retained" "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log"
  assert_match "exit event logged" "REAP_EXIT" "$(cat "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log")"
}

@test "cleanup does NOT append exit event when reaping TERMINATED state" {
  local issue="305"
  local worktree
  worktree=$(setup_worktree "$issue")
  setup_ipc "$issue"

  # Set state to TERMINATED (already completed)
  echo "TERMINATED:2026-07-09T00:00:00Z:ci-passed:55" > "${CEKERNEL_IPC_DIR}/worker-${issue}.state"

  # Create log file
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
  echo "[2026-07-09T00:00:00Z] SPAWN issue=#${issue}" > "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log"

  run bash "$CLEANUP_SCRIPT" "$issue"
  assert_eq "cleanup exits 0" "0" "$status"

  # No REAP_EXIT event for TERMINATED
  if grep -q "REAP_EXIT" "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.log" 2>/dev/null; then
    echo "FAIL: REAP_EXIT must not be logged for TERMINATED state" >&2
    return 1
  fi
}
