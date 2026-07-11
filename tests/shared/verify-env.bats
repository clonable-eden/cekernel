#!/usr/bin/env bats
# verify-env.bats — tests for scripts/shared/verify-env.sh
#
# verify-env.sh validates that required CEKERNEL_* env vars are set and
# that spawn-worker.sh is on PATH. It exits 1 with a descriptive error
# on any failure, and exits 0 silently on success (Rule of Silence).

load '../helpers/assertions'
load '../helpers/session'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  VERIFY="${CEKERNEL_DIR}/scripts/shared/verify-env.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  export CEKERNEL_ENV="${CEKERNEL_ENV:-default}"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"

  # Create a mock spawn-worker.sh on PATH
  MOCK_BIN="${BATS_TEST_TMPDIR}/mock-bin"
  mkdir -p "$MOCK_BIN"
  echo '#!/usr/bin/env bash' > "${MOCK_BIN}/spawn-worker.sh"
  chmod +x "${MOCK_BIN}/spawn-worker.sh"
  export PATH="${MOCK_BIN}:${PATH}"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

# ── success path ──

@test "verify-env exits 0 when all required vars are set and spawn-worker.sh is on PATH" {
  run bash "$VERIFY"
  assert_eq "exit status" "0" "$status"
}

@test "verify-env produces no output on success (Rule of Silence)" {
  run bash "$VERIFY"
  assert_eq "exit status" "0" "$status"
  assert_eq "no stdout" "" "$output"
}

# ── missing required vars ──

@test "verify-env exits 1 when CEKERNEL_SESSION_ID is unset" {
  unset CEKERNEL_SESSION_ID
  run bash "$VERIFY"
  assert_eq "exit status" "1" "$status"
  assert_match "error mentions CEKERNEL_SESSION_ID" "CEKERNEL_SESSION_ID" "$output"
}

@test "verify-env exits 1 when CEKERNEL_IPC_DIR is unset" {
  unset CEKERNEL_IPC_DIR
  run bash "$VERIFY"
  assert_eq "exit status" "1" "$status"
  assert_match "error mentions CEKERNEL_IPC_DIR" "CEKERNEL_IPC_DIR" "$output"
}

@test "verify-env exits 1 when CEKERNEL_ENV is unset" {
  unset CEKERNEL_ENV
  run bash "$VERIFY"
  assert_eq "exit status" "1" "$status"
  assert_match "error mentions CEKERNEL_ENV" "CEKERNEL_ENV" "$output"
}

@test "verify-env exits 1 when CEKERNEL_SESSION_ID is empty" {
  export CEKERNEL_SESSION_ID=""
  run bash "$VERIFY"
  assert_eq "exit status" "1" "$status"
  assert_match "error mentions CEKERNEL_SESSION_ID" "CEKERNEL_SESSION_ID" "$output"
}

# ── PATH check ──

@test "verify-env exits 1 when spawn-worker.sh is not on PATH" {
  export PATH="/usr/bin:/bin"
  run bash "$VERIFY"
  assert_eq "exit status" "1" "$status"
  assert_match "error mentions spawn-worker.sh" "spawn-worker.sh" "$output"
}
