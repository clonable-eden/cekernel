#!/usr/bin/env bash
# test-load-env.sh — Tests for load-env.sh (env profile loader)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOAD_ENV_SCRIPT="${CEKERNEL_DIR}/scripts/shared/load-env.sh"

echo "test: load-env.sh"

# ── Setup: create temporary directories for test env files ──
TEST_TMPDIR=$(mktemp -d)
PLUGIN_ENVS="${TEST_TMPDIR}/plugin-envs"
PROJECT_ENVS="${TEST_TMPDIR}/project-envs"
USER_ENVS="${TEST_TMPDIR}/user-envs"
NONEXISTENT_USER="${TEST_TMPDIR}/nonexistent-user"
mkdir -p "$PLUGIN_ENVS" "$PROJECT_ENVS" "$USER_ENVS"

cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# ── Test 1: Profile sets unset variables ──
cat > "${PLUGIN_ENVS}/test1.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=hello
CEKERNEL_TEST_VAR2=world
ENVFILE

RESULT=$(
  unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2 2>/dev/null || true
  export CEKERNEL_ENV=test1

  # Provide the plugin envs dir directly
  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="${TEST_TMPDIR}/nonexistent-project" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}"
)
assert_eq "Profile sets unset variables" "hello|world" "$RESULT"

# ── Test 2: Explicit env vars are NOT overwritten by profile ──
cat > "${PLUGIN_ENVS}/test2.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-profile
CEKERNEL_TEST_VAR2=from-profile
ENVFILE

RESULT=$(
  export CEKERNEL_TEST_VAR1="from-env"
  unset CEKERNEL_TEST_VAR2 2>/dev/null || true
  export CEKERNEL_ENV=test2

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="${TEST_TMPDIR}/nonexistent-project" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}"
)
assert_eq "Explicit env var wins over profile" "from-env|from-profile" "$RESULT"

# ── Test 3: Multi-layer priority — project overrides plugin ──
cat > "${PLUGIN_ENVS}/test3.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
CEKERNEL_TEST_VAR2=from-plugin
ENVFILE

cat > "${PROJECT_ENVS}/test3.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-project
ENVFILE

RESULT=$(
  unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2 2>/dev/null || true
  export CEKERNEL_ENV=test3

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="$PROJECT_ENVS" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}"
)
assert_eq "Project profile overrides plugin profile" "from-project|from-plugin" "$RESULT"

# ── Test 4: Missing profile file handled gracefully (no error) ──
RESULT=$(
  unset CEKERNEL_TEST_VAR1 2>/dev/null || true
  export CEKERNEL_ENV=nonexistent-profile

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="$PROJECT_ENVS" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT" 2>&1
  echo "ok"
)
assert_eq "Missing profile file handled gracefully" "ok" "$RESULT"

# ── Test 5: Comments and empty lines are skipped ──
cat > "${PLUGIN_ENVS}/test5.env" <<'ENVFILE'
# This is a comment
CEKERNEL_TEST_VAR1=value1

# Another comment

CEKERNEL_TEST_VAR2=value2
ENVFILE

RESULT=$(
  unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2 2>/dev/null || true
  export CEKERNEL_ENV=test5

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="${TEST_TMPDIR}/nonexistent-project" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}"
)
assert_eq "Comments and empty lines are skipped" "value1|value2" "$RESULT"

# ── Test 6: Default CEKERNEL_ENV is 'default' ──
cat > "${PLUGIN_ENVS}/default.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=default-value
ENVFILE

RESULT=$(
  unset CEKERNEL_TEST_VAR1 CEKERNEL_ENV 2>/dev/null || true

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="${TEST_TMPDIR}/nonexistent-project" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT"
  echo "$CEKERNEL_TEST_VAR1"
)
assert_eq "Default CEKERNEL_ENV is 'default'" "default-value" "$RESULT"

# ── Test 7: Values with special characters (spaces, paths) ──
cat > "${PLUGIN_ENVS}/test7.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=/some/path/value
CEKERNEL_TEST_VAR2=value with spaces
ENVFILE

RESULT=$(
  unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2 2>/dev/null || true
  export CEKERNEL_ENV=test7

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="${TEST_TMPDIR}/nonexistent-project" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}"
)
assert_eq "Values with paths and spaces handled" "/some/path/value|value with spaces" "$RESULT"

# ── Test 8: Full priority chain (env > project > plugin) ──
cat > "${PLUGIN_ENVS}/test8.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
CEKERNEL_TEST_VAR2=from-plugin
CEKERNEL_TEST_VAR3=from-plugin
ENVFILE

cat > "${PROJECT_ENVS}/test8.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-project
CEKERNEL_TEST_VAR2=from-project
ENVFILE

RESULT=$(
  export CEKERNEL_TEST_VAR1="from-env"
  unset CEKERNEL_TEST_VAR2 CEKERNEL_TEST_VAR3 2>/dev/null || true
  export CEKERNEL_ENV=test8

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="$PROJECT_ENVS" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}|${CEKERNEL_TEST_VAR3}"
)
assert_eq "Full priority: env > project > plugin" "from-env|from-project|from-plugin" "$RESULT"

# ── Test 9: User profile overrides project and plugin ──
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

RESULT=$(
  unset CEKERNEL_TEST_VAR1 CEKERNEL_TEST_VAR2 2>/dev/null || true
  export CEKERNEL_ENV=test9

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="$PROJECT_ENVS" \
  _CEKERNEL_USER_ENVS_DIR="$USER_ENVS" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}"
)
assert_eq "User profile overrides project and plugin" "from-user|from-user" "$RESULT"

# ── Test 10: Full priority chain (env > user > project > plugin) ──
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

RESULT=$(
  export CEKERNEL_TEST_VAR1="from-env"
  unset CEKERNEL_TEST_VAR2 CEKERNEL_TEST_VAR3 CEKERNEL_TEST_VAR4 2>/dev/null || true
  export CEKERNEL_ENV=test10

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="$PROJECT_ENVS" \
  _CEKERNEL_USER_ENVS_DIR="$USER_ENVS" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_TEST_VAR1}|${CEKERNEL_TEST_VAR2}|${CEKERNEL_TEST_VAR3}|${CEKERNEL_TEST_VAR4}"
)
assert_eq "Full priority: env > user > project > plugin" "from-env|from-user|from-project|from-plugin" "$RESULT"

# ── Test 11: Missing user profile handled gracefully ──
RESULT=$(
  unset CEKERNEL_TEST_VAR1 2>/dev/null || true
  export CEKERNEL_ENV=test11

  cat > "${PLUGIN_ENVS}/test11.env" <<'ENVFILE'
CEKERNEL_TEST_VAR1=from-plugin
ENVFILE

  _CEKERNEL_PLUGIN_ENVS_DIR="$PLUGIN_ENVS" \
  _CEKERNEL_PROJECT_ENVS_DIR="${TEST_TMPDIR}/nonexistent-project" \
  _CEKERNEL_USER_ENVS_DIR="$NONEXISTENT_USER" \
  source "$LOAD_ENV_SCRIPT" 2>&1
  echo "${CEKERNEL_TEST_VAR1}"
)
assert_eq "Missing user profile handled gracefully" "from-plugin" "$RESULT"

report_results
