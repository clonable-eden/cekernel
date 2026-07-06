#!/usr/bin/env bats
# zsh-compat.bats — parametrized zsh-compatibility tests for sourced shared helpers
#
# Consolidates the zsh-compat legacy clones (ADR-0017 Decision 4, #552):
#   - test-backend-adapter-zsh-compat.sh
#   - test-desktop-notify-zsh-compat.sh
#   - test-issue-lock-zsh-compat.sh
#   - test-load-env-zsh-compat.sh
#
# When sourced in zsh (e.g., Claude Code's Bash tool), BASH_SOURCE[0] does not
# resolve correctly; helpers need the ${(%):-%x} fallback. See #403, #405.

load '../helpers/assertions'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SHARED="${CEKERNEL_DIR}/scripts/shared"
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
}

# ── backend-adapter.sh / load-env.sh: script-dir resolution (parametrized) ──

@test "zsh: sourced helpers resolve their script dir (parametrized)" {
  local spec script var
  for spec in \
    "backend-adapter.sh|_BACKEND_ADAPTER_DIR" \
    "load-env.sh|_LOAD_ENV_DIR"; do
    script="${spec%%|*}"
    var="${spec#*|}"
    run zsh -c "export CEKERNEL_BACKEND=headless; \
      source '${SHARED}/${script}' 2>&1; \
      echo \"DIR:\${${var}}\""
    assert_match "zsh: ${script} resolves ${var} to scripts/shared" \
      "scripts/shared" "$output"
  done
}

@test "zsh: backend-adapter resolves backend dir for each backend (parametrized)" {
  local spec backend var
  for spec in \
    "tmux|_TMUX_BACKEND_DIR" \
    "wezterm|_WEZTERM_BACKEND_DIR"; do
    backend="${spec%%|*}"
    var="${spec#*|}"
    run zsh -c "export CEKERNEL_BACKEND=${backend}; \
      source '${SHARED}/backend-adapter.sh' 2>&1; \
      echo \"DIR:\${${var}}\""
    assert_match "zsh: ${var} resolves to backends dir" "backends" "$output"
  done
}

@test "zsh: backend-adapter loads headless backend functions" {
  run zsh -c "export CEKERNEL_BACKEND=headless; \
    source '${SHARED}/backend-adapter.sh' 2>&1; \
    if typeset -f backend_available >/dev/null 2>&1; then \
      echo 'FUNC_OK'; else echo 'FUNC_MISSING'; fi"
  assert_match "zsh: headless backend functions loaded" "FUNC_OK" "$output"
}

@test "bash: backend-adapter still loads headless backend functions (regression)" {
  run bash -c "export CEKERNEL_BACKEND=headless; \
    source '${SHARED}/backend-adapter.sh' 2>&1; \
    if declare -f backend_available >/dev/null 2>&1; then \
      echo 'FUNC_OK'; else echo 'FUNC_MISSING'; fi"
  assert_match "bash: backend-adapter.sh still works" "FUNC_OK" "$output"
}

# ── desktop-notify.sh ──

# Mocks uname (Darwin) and osascript so the macOS backend loads and the
# notification call is observable. Excludes homebrew paths from PATH so the
# osascript fallback (not an installed alerter) handles the notification.
setup_notify_mocks() {
  MOCK_LOG="${BATS_TEST_TMPDIR}/notify.log"
  : > "$MOCK_LOG"
  mock_bin uname 'echo "Darwin"'
  mock_bin osascript 'echo "osascript called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  SYSTEM_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -e homebrew -e '/usr/local/bin' | tr '\n' ':')
}

@test "zsh: desktop-notify resolves backend directory" {
  run zsh -c "source '${SHARED}/desktop-notify.sh'; \
    if [[ -d \"\${_DESKTOP_NOTIFY_DIR}/desktop-notify-backend\" ]]; then \
      echo 'found'; else echo 'not_found'; fi"
  assert_eq "zsh: _DESKTOP_NOTIFY_DIR resolves to directory with backend" \
    "found" "$output"
}

@test "zsh: desktop-notify loads real backend (osascript called, not no-op)" {
  setup_notify_mocks
  run zsh -c "export PATH='${MOCK_BIN_DIR}:${SYSTEM_PATH}'; \
    export DESKTOP_NOTIFY_MOCK_LOG='${MOCK_LOG}'; \
    source '${SHARED}/desktop-notify.sh'; \
    desktop_notify 'ZSH Title' 'ZSH Message'"
  assert_match "zsh: osascript called (real backend loaded, not no-op)" \
    "osascript called:" "$(cat "$MOCK_LOG" 2>/dev/null || echo '')"
}

@test "bash: desktop-notify still calls osascript (regression)" {
  setup_notify_mocks
  run bash -c "export PATH='${MOCK_BIN_DIR}:${SYSTEM_PATH}'; \
    export DESKTOP_NOTIFY_MOCK_LOG='${MOCK_LOG}'; \
    source '${SHARED}/desktop-notify.sh'; \
    desktop_notify 'Bash Title' 'Bash Message'"
  assert_match "bash: osascript called (regression check)" \
    "osascript called:" "$(cat "$MOCK_LOG" 2>/dev/null || echo '')"
}

# ── issue-lock.sh ──

@test "zsh: issue-lock sources without load-env resolution error" {
  run zsh -c "export CEKERNEL_VAR_DIR='${BATS_TEST_TMPDIR}/var'; \
    source '${SHARED}/issue-lock.sh' 2>&1; \
    echo 'SOURCE_OK'"
  assert_match "zsh: issue-lock.sh sources without error" "SOURCE_OK" "$output"
  if [[ "$output" == *"no such file or directory"* ]]; then
    echo "FAIL: zsh: load-env.sh resolution failed: ${output}" >&2
    return 1
  fi
}

@test "zsh: issue-lock functions work (repo hash)" {
  run zsh -c "export CEKERNEL_VAR_DIR='${BATS_TEST_TMPDIR}/var'; \
    source '${SHARED}/issue-lock.sh' 2>/dev/null; \
    HASH=\$(issue_lock_repo_hash '/tmp/test-repo'); \
    [[ -n \"\$HASH\" ]]"
  assert_eq "zsh: issue_lock_repo_hash function works" "0" "$status"
}

@test "zsh: issue-lock acquire/check/release cycle works" {
  run zsh -c "export CEKERNEL_VAR_DIR='${BATS_TEST_TMPDIR}/var'; \
    source '${SHARED}/issue-lock.sh' 2>/dev/null; \
    issue_lock_acquire '/tmp/test-zsh-repo' 403; \
    issue_lock_check '/tmp/test-zsh-repo' 403; \
    issue_lock_release '/tmp/test-zsh-repo' 403"
  assert_eq "zsh: lock acquire/check/release cycle works" "0" "$status"
}

@test "bash: issue-lock still works (regression)" {
  run bash -c "export CEKERNEL_VAR_DIR='${BATS_TEST_TMPDIR}/var'; \
    source '${SHARED}/issue-lock.sh'; \
    issue_lock_repo_hash '/tmp/test-repo' >/dev/null"
  assert_eq "bash: issue-lock.sh still works (regression check)" "0" "$status"
}

# ── load-env.sh ──

setup_zsh_env_fixture() {
  mkdir -p "${BATS_TEST_TMPDIR}/plugin-envs"
  printf 'CEKERNEL_TEST_ZSH_VAR=zsh_compat_ok\n' \
    > "${BATS_TEST_TMPDIR}/plugin-envs/default.env"
}

@test "zsh: load-env sources and loads env var" {
  setup_zsh_env_fixture
  run zsh -c "export CEKERNEL_ENV=default; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${BATS_TEST_TMPDIR}/plugin-envs'; \
    export _CEKERNEL_PROJECT_ENVS_DIR='${BATS_TEST_TMPDIR}/nonexistent'; \
    export _CEKERNEL_USER_ENVS_DIR='${BATS_TEST_TMPDIR}/nonexistent'; \
    source '${SHARED}/load-env.sh' 2>&1; \
    echo \"SOURCE_OK:\${CEKERNEL_TEST_ZSH_VAR:-unset}\""
  assert_match "zsh: load-env.sh sources and loads env var" \
    "SOURCE_OK:zsh_compat_ok" "$output"
}

@test "bash: load-env still loads env var (regression)" {
  setup_zsh_env_fixture
  run bash -c "export CEKERNEL_ENV=default; \
    export _CEKERNEL_PLUGIN_ENVS_DIR='${BATS_TEST_TMPDIR}/plugin-envs'; \
    export _CEKERNEL_PROJECT_ENVS_DIR='${BATS_TEST_TMPDIR}/nonexistent'; \
    export _CEKERNEL_USER_ENVS_DIR='${BATS_TEST_TMPDIR}/nonexistent'; \
    source '${SHARED}/load-env.sh' 2>&1; \
    echo \"SOURCE_OK:\${CEKERNEL_TEST_ZSH_VAR:-unset}\""
  assert_match "bash: load-env.sh still works (regression check)" \
    "SOURCE_OK:zsh_compat_ok" "$output"
}
