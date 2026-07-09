#!/usr/bin/env bats
# session-id.bats — bats-core tests for scripts/shared/session-id.sh

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SESSION_SCRIPT="${CEKERNEL_DIR}/scripts/shared/session-id.sh"
}

@test "session-id.sh generates CEKERNEL_SESSION_ID when unset" {
  run bash -c "unset CEKERNEL_SESSION_ID CEKERNEL_IPC_DIR; source '${SESSION_SCRIPT}'; echo \"\${CEKERNEL_SESSION_ID}\""
  assert_eq "source exits 0" "0" "$status"
  assert_match "matches {name}-{hex8}" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$output"
}

@test "session-id.sh preserves an existing CEKERNEL_SESSION_ID" {
  run bash -c "export CEKERNEL_SESSION_ID='my-custom-session-abc12345'; unset CEKERNEL_IPC_DIR; source '${SESSION_SCRIPT}'; echo \"\${CEKERNEL_SESSION_ID}\""
  assert_eq "existing ID preserved" "my-custom-session-abc12345" "$output"
}

@test "session-id.sh derives CEKERNEL_IPC_DIR from the session ID" {
  local expected_var_dir="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
  run bash -c "export CEKERNEL_SESSION_ID='test-session-aabbccdd'; unset CEKERNEL_IPC_DIR; source '${SESSION_SCRIPT}'; echo \"\${CEKERNEL_IPC_DIR}\""
  assert_eq "IPC dir derived" "${expected_var_dir}/ipc/test-session-aabbccdd" "$output"
}

# Step D (orchestrator-launch.md): unset before source forces new session scope
# See: #622 — Orchestrator launch must be a new-session boundary

@test "Step D pattern: unset + source generates new ID even when CEKERNEL_SESSION_ID is already set" {
  local old_id="cekernel-deadbeef"
  run bash -c "
    export CEKERNEL_SESSION_ID='${old_id}'
    unset CEKERNEL_SESSION_ID
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_SESSION_ID}\"
  "
  assert_eq "exits 0" "0" "$status"
  assert_match "new ID has {name}-{hex8} format" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$output"
  # Must differ from the old ID
  if [[ "$output" == "$old_id" ]]; then
    echo "FAIL: Step D reused old session ID: ${output}" >&2
    return 1
  fi
}

@test "Step D pattern: unset + source generates new ID from clean environment" {
  run bash -c "
    unset CEKERNEL_SESSION_ID
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_SESSION_ID}\"
  "
  assert_eq "exits 0" "0" "$status"
  assert_match "new ID has {name}-{hex8} format" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$output"
}

# ── .cekernel-env auto-discovery (issue #629) ──

@test "session-id.sh reads provisioned ID from .cekernel-env when CEKERNEL_SESSION_ID is unset" {
  # Create a temp git repo with .cekernel-env (simulates a Worker worktree)
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init --quiet
  echo "export CEKERNEL_SESSION_ID=cekernel-provisioned1" > "${tmpdir}/.cekernel-env"

  run bash -c "
    cd '$tmpdir'
    unset CEKERNEL_SESSION_ID
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_SESSION_ID}\"
  "
  rm -rf "$tmpdir"

  assert_eq "exits 0" "0" "$status"
  assert_eq "uses provisioned session ID" "cekernel-provisioned1" "$output"
}

@test "session-id.sh ignores .cekernel-env when CEKERNEL_SESSION_ID is already set" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init --quiet
  echo "export CEKERNEL_SESSION_ID=cekernel-provisioned2" > "${tmpdir}/.cekernel-env"

  run bash -c "
    cd '$tmpdir'
    export CEKERNEL_SESSION_ID='cekernel-explicit99'
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_SESSION_ID}\"
  "
  rm -rf "$tmpdir"

  assert_eq "exits 0" "0" "$status"
  assert_eq "keeps explicit ID" "cekernel-explicit99" "$output"
}

@test "session-id.sh derives correct IPC dir from .cekernel-env provisioned ID" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init --quiet
  echo "export CEKERNEL_SESSION_ID=cekernel-ipctest01" > "${tmpdir}/.cekernel-env"

  local expected_var_dir="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
  run bash -c "
    cd '$tmpdir'
    unset CEKERNEL_SESSION_ID
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_IPC_DIR}\"
  "
  rm -rf "$tmpdir"

  assert_eq "exits 0" "0" "$status"
  assert_eq "IPC dir uses provisioned ID" "${expected_var_dir}/ipc/cekernel-ipctest01" "$output"
}

@test "session-id.sh falls back to generation when no .cekernel-env exists" {
  # Use a temp git repo WITHOUT .cekernel-env
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init --quiet

  run bash -c "
    cd '$tmpdir'
    unset CEKERNEL_SESSION_ID
    unset CEKERNEL_IPC_DIR
    source '${SESSION_SCRIPT}'
    echo \"\${CEKERNEL_SESSION_ID}\"
  "
  rm -rf "$tmpdir"

  assert_eq "exits 0" "0" "$status"
  # Temp dir basename may contain uppercase (mktemp), so allow [A-Za-z]
  assert_match "generates new ID" "^[a-zA-Z0-9._-]+-[0-9a-f]{8}$" "$output"
}
