#!/usr/bin/env bats
# backend-adapter.bats — bats-core tests for scripts/shared/backend-adapter.sh
#
# Verifies backend dispatch based on CEKERNEL_BACKEND env var, API surface
# validation, and absence of legacy terminal_* functions.

load '../helpers/assertions'
load '../helpers/session'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ADAPTER="${CEKERNEL_DIR}/scripts/shared/backend-adapter.sh"

  set_test_session_id
  source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
  rm -rf "$CEKERNEL_IPC_DIR"
  mkdir -p "$CEKERNEL_IPC_DIR"
}

teardown() {
  rm -rf "$CEKERNEL_IPC_DIR"
}

@test "default backend is headless" {
  run bash -c "unset CEKERNEL_BACKEND; source '$ADAPTER' && echo \"\$CEKERNEL_ACTIVE_BACKEND\""
  assert_eq "exit 0" "0" "$status"
  assert_eq "default is headless" "headless" "$output"
}

@test "CEKERNEL_BACKEND=wezterm selects wezterm" {
  run bash -c "CEKERNEL_BACKEND=wezterm source '$ADAPTER' && echo \"\$CEKERNEL_ACTIVE_BACKEND\""
  assert_eq "exit 0" "0" "$status"
  assert_eq "wezterm selected" "wezterm" "$output"
}

@test "CEKERNEL_BACKEND=tmux selects tmux" {
  run bash -c "CEKERNEL_BACKEND=tmux source '$ADAPTER' && echo \"\$CEKERNEL_ACTIVE_BACKEND\""
  assert_eq "exit 0" "0" "$status"
  assert_eq "tmux selected" "tmux" "$output"
}

@test "CEKERNEL_BACKEND=headless selects headless" {
  run bash -c "CEKERNEL_BACKEND=headless source '$ADAPTER' && echo \"\$CEKERNEL_ACTIVE_BACKEND\""
  assert_eq "exit 0" "0" "$status"
  assert_eq "headless selected" "headless" "$output"
}

@test "unknown backend fails with error" {
  run bash -c "CEKERNEL_BACKEND=unknown_backend source '$ADAPTER' 2>/dev/null"
  assert_eq "exit non-zero" "1" "$status"
}

# Verify that each backend defines the required external API functions
_check_api_functions() {
  local backend="$1"
  local check=""
  local fn
  for fn in backend_available backend_spawn_worker backend_get_handle backend_worker_alive backend_kill_worker; do
    check="${check}declare -f ${fn} >/dev/null 2>&1 || echo ${fn}; "
  done
  run bash -c "CEKERNEL_BACKEND=${backend} source '$ADAPTER'; ${check}"
  assert_eq "${backend} exit 0" "0" "$status"
  assert_eq "${backend} defines all API functions" "" "$output"
}

@test "wezterm backend defines all 5 external API functions" {
  _check_api_functions wezterm
}

@test "tmux backend defines all 5 external API functions" {
  _check_api_functions tmux
}

@test "headless backend defines all 5 external API functions" {
  _check_api_functions headless
}

@test "no old terminal_* functions leak into API" {
  local check=""
  local fn
  for fn in terminal_available terminal_spawn_window terminal_run_command terminal_split_pane terminal_kill_pane terminal_kill_window terminal_pane_alive terminal_resolve_workspace terminal_spawn_worker_layout; do
    check="${check}declare -f ${fn} >/dev/null 2>&1 && echo ${fn}; "
  done
  run bash -c "CEKERNEL_BACKEND=wezterm source '$ADAPTER'; ${check} true"
  assert_eq "exit 0" "0" "$status"
  assert_eq "no old functions found" "" "$output"
}
