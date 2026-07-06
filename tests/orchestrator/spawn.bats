#!/usr/bin/env bats
# spawn.bats — bats-core tests for scripts/orchestrator/spawn.sh
#
# Runs spawn.sh end-to-end with mocked gh/claude in a temp clone
# (headless backend) and asserts the recorded claude argv (ADR-0017) —
# never the text of generated scripts.
#
# Covers --fallback-model / CEKERNEL_FALLBACK_MODEL passthrough (#529).

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
  TMP="$(mktemp -d)"

  # Upstream repo + clone (spawn.sh runs `git fetch origin <base>`)
  git init -q -b main "${TMP}/upstream"
  git -C "${TMP}/upstream" -c user.email=test@test -c user.name=test \
    commit -q --allow-empty -m "init"
  git clone -q "${TMP}/upstream" "${TMP}/repo"

  # Mock gh: spawn.sh reads the title, task-file.sh reads full JSON
  MOCK_BIN="${TMP}/bin"
  mkdir -p "$MOCK_BIN"
  cat > "${MOCK_BIN}/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"-q"* ]]; then
  echo "Test issue"
else
  echo '{"title":"Test issue","body":"test body","labels":[],"comments":[]}'
fi
GH
  # Mock claude: record argv (executed effect, not generated text)
  ARGS_FILE="${TMP}/claude-args.txt"
  cat > "${MOCK_BIN}/claude" <<CLAUDE
#!/usr/bin/env bash
printf '%s\n' "\$@" > '${ARGS_FILE}'
CLAUDE
  chmod +x "${MOCK_BIN}/gh" "${MOCK_BIN}/claude"
  export PATH="${MOCK_BIN}:${PATH}"

  # Isolation: session/IPC/locks under TMP, trust file, bare auth, backend
  export CEKERNEL_SESSION_ID="test-spawn-fallback-$$"
  export CEKERNEL_VAR_DIR="${TMP}/var"
  unset CEKERNEL_IPC_DIR
  export CLAUDE_JSON="${TMP}/claude.json"
  export ANTHROPIC_API_KEY="test-key-bare"
  export CEKERNEL_BACKEND="headless"

  # Neutral env profiles — plugin defaults (headless.env) must not leak
  # CEKERNEL_FALLBACK_MODEL into tests that assert the unset behavior.
  mkdir -p "${TMP}/envs"
  export _CEKERNEL_PLUGIN_ENVS_DIR="${TMP}/envs"
  export _CEKERNEL_PROJECT_ENVS_DIR="${TMP}/envs"
  export _CEKERNEL_USER_ENVS_DIR="${TMP}/envs"
  unset CEKERNEL_FALLBACK_MODEL CEKERNEL_CLAUDE_SETTINGS
}

teardown() {
  rm -rf "$TMP"
}

# run_spawn [extra-flags...] — run spawn.sh for issue 42 against base main
run_spawn() {
  run bash -c "cd '${TMP}/repo' && bash '${SPAWN_SCRIPT}' --agent worker $* 42 main"
}

@test "spawn.sh --fallback-model forwards the model to claude argv" {
  run_spawn --fallback-model my-fallback
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(tr '\n' ' ' < "$ARGS_FILE")"
  assert_match "claude argv pairs flag with model" "--fallback-model my-fallback" "$argv"
}

@test "spawn.sh forwards CEKERNEL_FALLBACK_MODEL from the environment" {
  export CEKERNEL_FALLBACK_MODEL="env-model"
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(tr '\n' ' ' < "$ARGS_FILE")"
  assert_match "claude argv pairs flag with env model" "--fallback-model env-model" "$argv"
}

@test "spawn.sh --fallback-model overrides CEKERNEL_FALLBACK_MODEL" {
  export CEKERNEL_FALLBACK_MODEL="env-model"
  run_spawn --fallback-model flag-model
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(tr '\n' ' ' < "$ARGS_FILE")"
  assert_match "flag wins over env" "--fallback-model flag-model" "$argv"
  if [[ "$argv" == *"env-model"* ]]; then
    echo "FAIL: env model must not appear when flag is given: ${argv}" >&2
    return 1
  fi
}

@test "spawn.sh omits --fallback-model when nothing is configured" {
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(cat "$ARGS_FILE")"
  if [[ "$argv" == *"--fallback-model"* ]]; then
    echo "FAIL: --fallback-model must not appear by default: ${argv}" >&2
    return 1
  fi
}
