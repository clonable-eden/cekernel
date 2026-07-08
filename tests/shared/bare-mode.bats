#!/usr/bin/env bats
# bare-mode.bats — bats-core tests for scripts/shared/bare-mode.sh
#
# Covers CEKERNEL_FALLBACK_MODEL → --fallback-model flag building (#529)
# and conditional --bare on auth availability (ADR-0016 Amendment 1, #574):
# a bare-compatible auth path (ANTHROPIC_API_KEY or CEKERNEL_CLAUDE_SETTINGS)
# keeps --bare; otherwise --bare is dropped (OAuth/keychain auth) with a
# one-line stderr notice, while context injection (--plugin-dir/--add-dir)
# is preserved.
# Legacy coverage for --plugin-dir/--add-dir/--settings/preflight
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

# ── Conditional --bare on auth availability (ADR-0016 Amendment 1, #574) ──

@test "bare_mode_prepare includes --bare when ANTHROPIC_API_KEY is set" {
  run bash -c "unset CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL; export ANTHROPIC_API_KEY='test-key'; source '${BARE_SCRIPT}'; bare_mode_prepare; printf '%s ' \"\${CEKERNEL_BARE_FLAGS[@]}\""
  assert_eq "prepare exits 0" "0" "$status"
  assert_match "argv has --bare" "--bare" "$output"
}

@test "bare_mode_prepare includes --bare when CEKERNEL_CLAUDE_SETTINGS is set" {
  local settings="${BATS_TEST_TMPDIR}/settings.json"
  echo '{}' > "$settings"
  run bash -c "unset ANTHROPIC_API_KEY CEKERNEL_FALLBACK_MODEL; export CEKERNEL_CLAUDE_SETTINGS='${settings}'; source '${BARE_SCRIPT}'; bare_mode_prepare; printf '%s ' \"\${CEKERNEL_BARE_FLAGS[@]}\""
  assert_eq "prepare exits 0" "0" "$status"
  assert_match "argv has --bare" "--bare" "$output"
  assert_match "argv has --settings" "--settings ${settings}" "$output"
}

@test "bare_mode_prepare drops --bare without bare-compatible auth" {
  run bash -c "unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL; source '${BARE_SCRIPT}'; bare_mode_prepare 2>/dev/null; printf '%s ' \"\${CEKERNEL_BARE_FLAGS[@]}\""
  assert_eq "prepare exits 0" "0" "$status"
  if [[ "$output" == *"--bare"* ]]; then
    echo "FAIL: --bare must not appear without API-key auth: ${output}" >&2
    return 1
  fi
}

@test "bare_mode_prepare keeps context injection without bare-compatible auth" {
  local ctx="${BATS_TEST_TMPDIR}/ctx"
  mkdir -p "$ctx"
  run bash -c "unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL; source '${BARE_SCRIPT}'; bare_mode_prepare '${ctx}' 2>/dev/null; printf '%s ' \"\${CEKERNEL_BARE_FLAGS[@]}\""
  assert_eq "prepare exits 0" "0" "$status"
  assert_match "argv keeps --plugin-dir" "--plugin-dir ${CEKERNEL_DIR}" "$output"
  assert_match "argv keeps --add-dir" "--add-dir ${ctx}" "$output"
}

@test "bare_mode_prepare emits a one-line stderr notice without bare-compatible auth" {
  run bash -c "unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL; source '${BARE_SCRIPT}'; bare_mode_prepare 2>&1 >/dev/null"
  assert_eq "prepare exits 0" "0" "$status"
  assert_match "notice mentions bare mode disabled" "bare mode disabled" "$output"
}

@test "bare_mode_prepare emits no notice when bare-compatible auth exists" {
  run bash -c "unset CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL; export ANTHROPIC_API_KEY='test-key'; source '${BARE_SCRIPT}'; bare_mode_prepare 2>&1 >/dev/null"
  assert_eq "prepare exits 0" "0" "$status"
  assert_eq "stderr is silent (Rule of Silence)" "" "$output"
}

@test "bare_mode_flags excludes --bare and keeps notice out of the flag string" {
  local flags
  flags=$(bash -c "unset ANTHROPIC_API_KEY CEKERNEL_CLAUDE_SETTINGS CEKERNEL_FALLBACK_MODEL; source '${BARE_SCRIPT}'; bare_mode_flags" 2>/dev/null)
  if [[ "$flags" == *"--bare"* ]]; then
    echo "FAIL: --bare must not appear without API-key auth: ${flags}" >&2
    return 1
  fi
  if [[ "$flags" == *"notice"* ]]; then
    echo "FAIL: stderr notice leaked into the flag string: ${flags}" >&2
    return 1
  fi
  assert_match "flags string keeps --plugin-dir" "--plugin-dir ${CEKERNEL_DIR}" "$flags"
}
