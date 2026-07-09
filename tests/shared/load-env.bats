#!/usr/bin/env bats
# load-env.bats — bats-core tests for scripts/shared/load-env.sh
#
# Consolidates (ADR-0017 Decision 4, #552):
#   - test-load-env.sh             (profile layering / parsing behavior)
#   - test-load-env-ci-retries.sh  (CEKERNEL_CI_MAX_RETRIES default, ADR-0010 / #82)
#   - test-load-env-integration.sh (orchestrator scripts source load-env, #373)
# plus the CEKERNEL_FALLBACK_MODEL default in the headless profile (#529).
# zsh-compat coverage lives in tests/shared/zsh-compat.bats.

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LOAD_ENV="${CEKERNEL_DIR}/scripts/shared/load-env.sh"
  PLUGIN_ENVS="${BATS_TEST_TMPDIR}/plugin-envs"
  PROJECT_ENVS="${BATS_TEST_TMPDIR}/project-envs"
  USER_ENVS="${BATS_TEST_TMPDIR}/user-envs"
  NEUTRAL_DIR="${BATS_TEST_TMPDIR}/neutral"   # exists but holds no profiles
  mkdir -p "$PLUGIN_ENVS" "$PROJECT_ENVS" "$USER_ENVS" "$NEUTRAL_DIR"
}

# ── Profile layering / parsing ──

@test "profile sets unset variables" {
  cat > "${PLUGIN_ENVS}/test1.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=hello
CEKERNEL_TEST_VAR2=world
ENVFILE
  run bash -c "unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2; \
    export CEKERNEL_ENV=test1; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}\""
  assert_eq "Profile sets unset variables" "hello|world" "$output"
}

@test "explicit env var wins over profile" {
  cat > "${PLUGIN_ENVS}/test2.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-profile
CEKERNEL_TEST_VAR2=from-profile
ENVFILE
  run bash -c "export CEKERNEL_TEST_VAR1='from-env'; \
    unset CEKERNEL_TEST_VAR2; \
    export CEKERNEL_ENV=test2; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}\""
  assert_eq "Explicit env var wins over profile" "from-env|from-profile" "$output"
}

@test "project profile overrides plugin profile" {
  cat > "${PLUGIN_ENVS}/test3.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
CEKERNEL_TEST_VAR2=from-plugin
ENVFILE
  cat > "${PROJECT_ENVS}/test3.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-project
ENVFILE
  run bash -c "unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2; \
    export CEKERNEL_ENV=test3; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${PROJECT_ENVS}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}\""
  assert_eq "Project profile overrides plugin profile" \
    "from-project|from-plugin" "$output"
}

@test "missing profile file handled gracefully" {
  run bash -c "unset CEKERNEL_TEST_VAR1; \
    export CEKERNEL_ENV=nonexistent-profile; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${PROJECT_ENVS}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}' 2>&1; \
    echo 'ok'"
  assert_eq "Missing profile file handled gracefully" "ok" "$output"
}

@test "comments and empty lines are skipped" {
  cat > "${PLUGIN_ENVS}/test5.env" <<'ENVFILE'
# This is a comment
CEKERNEL_TEST_VAR1=value1

# Another comment

CEKERNEL_TEST_VAR2=value2
ENVFILE
  run bash -c "unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2; \
    export CEKERNEL_ENV=test5; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}\""
  assert_eq "Comments and empty lines are skipped" "value1|value2" "$output"
}

@test "default CEKERNEL_ENV is 'default'" {
  cat > "${PLUGIN_ENVS}/default.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=default-value
ENVFILE
  run bash -c "unset CEKERNEL_TEST_VAR1 CEKERNEL_ENV; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}\""
  assert_eq "Default CEKERNEL_ENV is 'default'" "default-value" "$output"
}

@test "values with paths and spaces handled" {
  cat > "${PLUGIN_ENVS}/test7.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=/some/path/value
CEKERNEL_TEST_VAR2=value with spaces
ENVFILE
  run bash -c "unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2; \
    export CEKERNEL_ENV=test7; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}\""
  assert_eq "Values with paths and spaces handled" \
    "/some/path/value|value with spaces" "$output"
}

@test "full priority: env > project > plugin" {
  cat > "${PLUGIN_ENVS}/test8.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
CEKERNEL_TEST_VAR2=from-plugin
CEKERNEL_TEST_VAR3=from-plugin
ENVFILE
  cat > "${PROJECT_ENVS}/test8.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-project
CEKERNEL_TEST_VAR2=from-project
ENVFILE
  run bash -c "export CEKERNEL_TEST_VAR1='from-env'; \
    unset CEKERNEL_TEST_VAR2 CEKERNEL_TEST_VAR3; \
    export CEKERNEL_ENV=test8; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${PROJECT_ENVS}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}|\${CEKERNEL_TEST_VAR3}\""
  assert_eq "Full priority: env > project > plugin" \
    "from-env|from-project|from-plugin" "$output"
}

@test "user profile overrides project and plugin" {
  cat > "${PLUGIN_ENVS}/test9.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
CEKERNEL_TEST_VAR2=from-plugin
ENVFILE
  cat > "${PROJECT_ENVS}/test9.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-project
ENVFILE
  cat > "${USER_ENVS}/test9.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-user
CEKERNEL_TEST_VAR2=from-user
ENVFILE
  run bash -c "unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2; \
    export CEKERNEL_ENV=test9; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${PROJECT_ENVS}' \
           _CEKERNEL_USER_ENVS_DIR='${USER_ENVS}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}\""
  assert_eq "User profile overrides project and plugin" \
    "from-user|from-user" "$output"
}

@test "full priority: env > user > project > plugin" {
  cat > "${PLUGIN_ENVS}/test10.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
CEKERNEL_TEST_VAR2=from-plugin
CEKERNEL_TEST_VAR3=from-plugin
CEKERNEL_TEST_VAR4=from-plugin
ENVFILE
  cat > "${PROJECT_ENVS}/test10.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-project
CEKERNEL_TEST_VAR2=from-project
CEKERNEL_TEST_VAR3=from-project
ENVFILE
  cat > "${USER_ENVS}/test10.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-user
CEKERNEL_TEST_VAR2=from-user
ENVFILE
  run bash -c "export CEKERNEL_TEST_VAR1='from-env'; \
    unset CEKERNEL_TEST_VAR2 CEKERNEL_TEST_VAR3 CEKERNEL_TEST_VAR4; \
    export CEKERNEL_ENV=test10; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${PROJECT_ENVS}' \
           _CEKERNEL_USER_ENVS_DIR='${USER_ENVS}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_TEST_VAR1}|\${CEKERNEL_TEST_VAR2}|\${CEKERNEL_TEST_VAR3}|\${CEKERNEL_TEST_VAR4}\""
  assert_eq "Full priority: env > user > project > plugin" \
    "from-env|from-user|from-project|from-plugin" "$output"
}

@test "missing user profile handled gracefully" {
  cat > "${PLUGIN_ENVS}/test11.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
ENVFILE
  run bash -c "unset CEKERNEL_TEST_VAR1; \
    export CEKERNEL_ENV=test11; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${PLUGIN_ENVS}' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${BATS_TEST_TMPDIR}/nonexistent-user'; \
    source '${LOAD_ENV}' 2>&1; \
    echo \"\${CEKERNEL_TEST_VAR1}\""
  assert_eq "Missing user profile handled gracefully" "from-plugin" "$output"
}

# ── Plugin default profile values (real envs/ directory) ──

@test "default profile sets CEKERNEL_CI_MAX_RETRIES=3" {
  run bash -c "unset CEKERNEL_CI_MAX_RETRIES CEKERNEL_ENV; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${CEKERNEL_DIR}/envs' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_CI_MAX_RETRIES:-UNSET}\""
  assert_eq "Default profile sets CEKERNEL_CI_MAX_RETRIES=3" "3" "$output"
}

@test "explicit CEKERNEL_CI_MAX_RETRIES overrides profile" {
  run bash -c "export CEKERNEL_CI_MAX_RETRIES=5; \
    unset CEKERNEL_ENV; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${CEKERNEL_DIR}/envs' \
           _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_CI_MAX_RETRIES}\""
  assert_eq "Explicit CEKERNEL_CI_MAX_RETRIES overrides profile" "5" "$output"
}

@test "project profile overrides plugin CEKERNEL_CI_MAX_RETRIES" {
  cat > "${PROJECT_ENVS}/default.env" <<'ENVFILE'
CEKERNEL_CI_MAX_RETRIES=7
ENVFILE
  run bash -c "unset CEKERNEL_CI_MAX_RETRIES CEKERNEL_ENV; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${CEKERNEL_DIR}/envs' \
           _CEKERNEL_PROJECT_ENVS_DIR='${PROJECT_ENVS}' \
           _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_CI_MAX_RETRIES}\""
  assert_eq "Project profile overrides plugin CEKERNEL_CI_MAX_RETRIES" \
    "7" "$output"
}

@test "headless profile provides a CEKERNEL_FALLBACK_MODEL default" {
  run bash -c "unset CEKERNEL_FALLBACK_MODEL; \
    export CEKERNEL_ENV=headless; \
    export _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_FALLBACK_MODEL:-}\""
  assert_eq "load-env exits 0" "0" "$status"
  assert_eq "headless.env sets fallback model" "claude-haiku-4-5-20251001" "$output"
}

@test "explicit CEKERNEL_FALLBACK_MODEL export wins over the headless profile" {
  run bash -c "export CEKERNEL_FALLBACK_MODEL='user-choice'; \
    export CEKERNEL_ENV=headless; \
    export _CEKERNEL_PROJECT_ENVS_DIR='${NEUTRAL_DIR}' _CEKERNEL_USER_ENVS_DIR='${NEUTRAL_DIR}'; \
    source '${LOAD_ENV}'; \
    echo \"\${CEKERNEL_FALLBACK_MODEL}\""
  assert_eq "load-env exits 0" "0" "$status"
  assert_eq "explicit export preserved" "user-choice" "$output"
}

# ── Orchestrator integration (#373) ──
# Orchestrator scripts must source load-env.sh before session-id.sh so that
# CEKERNEL_VAR_DIR from the user profile is respected (instead of falling
# back to the hardcoded default).

setup_orchestrator_fixture() {
  MOCK_USER_ENVS="${BATS_TEST_TMPDIR}/int-user-envs"
  MOCK_VAR_DIR="${BATS_TEST_TMPDIR}/int-custom-var"
  TEST_SESSION="test-loadenv-00000001"
  mkdir -p "$MOCK_USER_ENVS" "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}"
  printf 'CEKERNEL_VAR_DIR=%s\n' "$MOCK_VAR_DIR" > "${MOCK_USER_ENVS}/default.env"
  echo "RUNNING:2026-02-28T10:00:00Z:phase1:implement" > "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/worker-99.state"
}

# Runs a script with CEKERNEL_VAR_DIR unset and the user profile pointing to
# the custom var dir — the #373 scenario: the script must discover
# CEKERNEL_VAR_DIR from the user profile via load-env.sh.
run_with_user_profile() {
  local script="$1"
  shift
  env -u CEKERNEL_VAR_DIR \
    CEKERNEL_SESSION_ID="$TEST_SESSION" \
    CEKERNEL_ENV=default \
    _CEKERNEL_USER_ENVS_DIR="$MOCK_USER_ENVS" \
    _CEKERNEL_PROJECT_ENVS_DIR="${BATS_TEST_TMPDIR}/nonexistent-project" \
    _CEKERNEL_PLUGIN_ENVS_DIR="${BATS_TEST_TMPDIR}/nonexistent-plugin" \
    bash "$script" "$@" 2>&1
}

@test "process-status.sh uses CEKERNEL_VAR_DIR from user profile" {
  setup_orchestrator_fixture
  run run_with_user_profile "${CEKERNEL_DIR}/scripts/orchestrator/process-status.sh"
  assert_match "process-status.sh finds worker via user profile CEKERNEL_VAR_DIR" \
    '"issue":99' "$output"
  if [[ "$output" == *"No active session"* ]]; then
    echo "FAIL: process-status.sh reported missing session: ${output}" >&2
    return 1
  fi
}

@test "health-check.sh uses CEKERNEL_VAR_DIR from user profile" {
  setup_orchestrator_fixture
  # When load-env works, health-check finds the worker state file and does
  # not report "No active workers" (which it would at the wrong default path).
  run run_with_user_profile "${CEKERNEL_DIR}/scripts/orchestrator/health-check.sh" 99
  if [[ "$output" == *"No active workers"* ]]; then
    echo "FAIL: health-check.sh did not find state file via user profile: ${output}" >&2
    return 1
  fi
}

@test "send-signal.sh uses CEKERNEL_VAR_DIR from user profile" {
  setup_orchestrator_fixture
  run run_with_user_profile "${CEKERNEL_DIR}/scripts/orchestrator/send-signal.sh" 99 TERM
  if [[ "$output" == *"IPC directory not found"* ]]; then
    echo "FAIL: send-signal.sh reported missing IPC dir: ${output}" >&2
    return 1
  fi
  assert_file_exists "send-signal.sh creates signal in custom var dir" \
    "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/worker-99.signal"
}

@test "watch-logs.sh uses CEKERNEL_VAR_DIR from user profile" {
  # 'tail -f' blocks forever without timeout — skip rather than pass vacuously
  # (macOS has no timeout by default; CI runs on Linux where it exists).
  command -v timeout >/dev/null 2>&1 || skip "timeout not available"
  setup_orchestrator_fixture
  # watch-logs.sh uses 'tail -f' which blocks — bound it with timeout and
  # check for the failure message (absence means the custom dir was found).
  mkdir -p "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/logs"
  echo "test log" > "${MOCK_VAR_DIR}/ipc/${TEST_SESSION}/logs/worker-99.log"
  run timeout 2 env -u CEKERNEL_VAR_DIR \
    CEKERNEL_SESSION_ID="$TEST_SESSION" \
    CEKERNEL_ENV=default \
    _CEKERNEL_USER_ENVS_DIR="$MOCK_USER_ENVS" \
    _CEKERNEL_PROJECT_ENVS_DIR="${BATS_TEST_TMPDIR}/nonexistent-project" \
    _CEKERNEL_PLUGIN_ENVS_DIR="${BATS_TEST_TMPDIR}/nonexistent-plugin" \
    bash "${CEKERNEL_DIR}/scripts/orchestrator/watch-logs.sh" 99
  if [[ "$output" == *"No log directory found"* ]]; then
    echo "FAIL: watch-logs.sh reported missing log dir: ${output}" >&2
    return 1
  fi
}
