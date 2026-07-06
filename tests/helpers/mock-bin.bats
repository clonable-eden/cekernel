#!/usr/bin/env bats
# mock-bin.bats — contract self-tests for tests/helpers/mock-bin.bash
#
# ADR-0017 Decision 2: PATH shims are the single sanctioned mock style.
# These tests verify the observable behavior of the mock_bin helper.

load '../helpers/assertions'
load '../helpers/mock-bin'

@test "mock_bin shim intercepts a command invoked by name" {
  mock_bin cekernel-fake-cmd 'echo "mocked-output"'
  run cekernel-fake-cmd
  assert_eq "exit status" "0" "$status"
  assert_eq "output" "mocked-output" "$output"
}

@test "mock_bin shim receives its arguments" {
  mock_bin cekernel-fake-cmd 'printf "%s\n" "$@"'
  run cekernel-fake-cmd one two
  assert_eq "first line" "one" "${lines[0]}"
  assert_eq "second line" "two" "${lines[1]}"
}

@test "mock_bin shadows a real command for by-name invocation" {
  mock_bin uname 'echo "mock-uname"'
  run uname
  assert_eq "real command shadowed" "mock-uname" "$output"
}

@test "mock_bin shim survives exec boundaries (visible in child processes)" {
  # This is the property function overrides lack (ADR-0017: they silently
  # fail across exec/subshell spawn paths).
  mock_bin cekernel-fake-cmd 'echo "from-shim"'
  run bash -c 'cekernel-fake-cmd'
  assert_eq "shim visible in child process" "from-shim" "$output"
}

@test "mock_bin uses the single variable name MOCK_BIN_DIR under BATS_TEST_TMPDIR" {
  mock_bin cekernel-fake-cmd 'true'
  [[ "$MOCK_BIN_DIR" == "${BATS_TEST_TMPDIR}"/* ]] || {
    echo "FAIL: MOCK_BIN_DIR not under BATS_TEST_TMPDIR: $MOCK_BIN_DIR" >&2
    return 1
  }
  assert_file_exists "shim file" "${MOCK_BIN_DIR}/cekernel-fake-cmd"
}

@test "calling mock_bin twice for the same command replaces the shim" {
  mock_bin cekernel-fake-cmd 'echo "first"'
  mock_bin cekernel-fake-cmd 'echo "second"'
  run cekernel-fake-cmd
  assert_eq "latest shim wins" "second" "$output"
}

@test "mock_bin supports multiple distinct commands in one test" {
  mock_bin cekernel-fake-a 'echo "a"'
  mock_bin cekernel-fake-b 'echo "b"'
  run cekernel-fake-a
  assert_eq "first shim" "a" "$output"
  run cekernel-fake-b
  assert_eq "second shim" "b" "$output"
}
