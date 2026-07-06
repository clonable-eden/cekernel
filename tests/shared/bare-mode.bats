#!/usr/bin/env bats
# bare-mode.bats — bats-core tests for scripts/shared/bare-mode.sh
#
# Covers CEKERNEL_FALLBACK_MODEL → --fallback-model flag building (#529).
# Legacy coverage for --bare/--plugin-dir/--add-dir/--settings/preflight
# lives in tests/shared/test-bare-mode.sh (pre-ADR-0017 harness).

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BARE_SCRIPT="${CEKERNEL_DIR}/scripts/shared/bare-mode.sh"
}

@test "bare_mode_prepare adds --fallback-model when CEKERNEL_FALLBACK_MODEL is set" {
  run bash -c "unset CEKERNEL_CLAUDE_SETTINGS; export CEKERNEL_FALLBACK_MODEL='claude-haiku-4-5-20251001'; source '${BARE_SCRIPT}'; bare_mode_prepare; printf '%s ' \"\${CEKERNEL_BARE_FLAGS[@]}\""
  assert_eq "prepare exits 0" "0" "$status"
  assert_match "argv pairs flag with model" "--fallback-model claude-haiku-4-5-20251001" "$output"
}

@test "bare_mode_prepare omits --fallback-model when CEKERNEL_FALLBACK_MODEL is unset" {
  run bash -c "unset CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL; source '${BARE_SCRIPT}'; bare_mode_prepare; printf '%s ' \"\${CEKERNEL_BARE_FLAGS[@]}\""
  assert_eq "prepare exits 0" "0" "$status"
  if [[ "$output" == *"--fallback-model"* ]]; then
    echo "FAIL: --fallback-model must not appear when unset: ${output}" >&2
    return 1
  fi
}

@test "bare_mode_prepare omits --fallback-model when CEKERNEL_FALLBACK_MODEL is empty" {
  run bash -c "unset CEKERNEL_CLAUDE_SETTINGS; export CEKERNEL_FALLBACK_MODEL=''; source '${BARE_SCRIPT}'; bare_mode_prepare; printf '%s ' \"\${CEKERNEL_BARE_FLAGS[@]}\""
  assert_eq "prepare exits 0" "0" "$status"
  if [[ "$output" == *"--fallback-model"* ]]; then
    echo "FAIL: --fallback-model must not appear when empty: ${output}" >&2
    return 1
  fi
}

@test "bare_mode_flags embeds --fallback-model for generated runners" {
  run bash -c "unset CEKERNEL_CLAUDE_SETTINGS; export CEKERNEL_FALLBACK_MODEL='test-model'; source '${BARE_SCRIPT}'; bare_mode_flags"
  assert_eq "flags exits 0" "0" "$status"
  assert_match "flags string pairs flag with model" "--fallback-model test-model" "$output"
}
