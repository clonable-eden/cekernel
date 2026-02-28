#!/usr/bin/env bash
# test-load-env-ci-retries.sh — Tests that default.env provides CEKERNEL_CI_MAX_RETRIES
#
# Verifies that load-env.sh with the default profile sets CEKERNEL_CI_MAX_RETRIES=3,
# as required by ADR-0010 and issue #82.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOAD_ENV_SCRIPT="${CEKERNEL_DIR}/scripts/shared/load-env.sh"

echo "test: load-env-ci-retries"

# ── Test 1: Default profile sets CEKERNEL_CI_MAX_RETRIES=3 ──
RESULT=$(
  unset CEKERNEL_CI_MAX_RETRIES CEKERNEL_ENV 2>/dev/null || true

  # Use the real plugin envs directory (not a test override)
  _CEKERNEL_PLUGIN_ENVS_DIR="${CEKERNEL_DIR}/envs" \
  _CEKERNEL_PROJECT_ENVS_DIR="$(mktemp -d)/nonexistent" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_CI_MAX_RETRIES:-UNSET}"
)
assert_eq "Default profile sets CEKERNEL_CI_MAX_RETRIES=3" "3" "$RESULT"

# ── Test 2: Explicit env var overrides default profile ──
RESULT=$(
  export CEKERNEL_CI_MAX_RETRIES=5
  unset CEKERNEL_ENV 2>/dev/null || true

  _CEKERNEL_PLUGIN_ENVS_DIR="${CEKERNEL_DIR}/envs" \
  _CEKERNEL_PROJECT_ENVS_DIR="$(mktemp -d)/nonexistent" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_CI_MAX_RETRIES}"
)
assert_eq "Explicit CEKERNEL_CI_MAX_RETRIES overrides profile" "5" "$RESULT"

# ── Test 3: Project profile can override plugin default ──
PROJECT_TMPDIR=$(mktemp -d)
mkdir -p "${PROJECT_TMPDIR}/envs"
cat > "${PROJECT_TMPDIR}/envs/default.env" <<'ENVFILE'
CEKERNEL_CI_MAX_RETRIES=7
ENVFILE

RESULT=$(
  unset CEKERNEL_CI_MAX_RETRIES CEKERNEL_ENV 2>/dev/null || true

  _CEKERNEL_PLUGIN_ENVS_DIR="${CEKERNEL_DIR}/envs" \
  _CEKERNEL_PROJECT_ENVS_DIR="${PROJECT_TMPDIR}/envs" \
  source "$LOAD_ENV_SCRIPT"
  echo "${CEKERNEL_CI_MAX_RETRIES}"
)
assert_eq "Project profile overrides plugin CEKERNEL_CI_MAX_RETRIES" "7" "$RESULT"

rm -rf "$PROJECT_TMPDIR"

report_results
