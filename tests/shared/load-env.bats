#!/usr/bin/env bats
# load-env.bats — bats-core tests for scripts/shared/load-env.sh
#
# Covers the CEKERNEL_FALLBACK_MODEL default in the headless profile (#529).
# Legacy coverage for layering/zsh-compat lives in tests/shared/test-load-env*.sh.

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LOAD_ENV="${CEKERNEL_DIR}/scripts/shared/load-env.sh"
  NEUTRAL_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$NEUTRAL_DIR"
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
