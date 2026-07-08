# mock-bin.bash — canonical PATH-shim mock helper (ADR-0017 Decision 2)
#
# PATH shims are the ONLY sanctioned mock style in this test suite.
# Shell-function overrides are BANNED: they silently fail across
# exec/subshell boundaries (a script that execs `git` never sees a
# function named `git`), which is exactly where spawn-path bugs hide.
# Do not add new function-override mocks.
#
# Precondition: PATH shims only intercept commands invoked BY NAME.
# Scripts that call absolute paths (e.g. /usr/bin/git) bypass the shim
# entirely. If a subject script hardcodes an absolute path, restructure
# the script (or the test) — do not fall back to function overrides.
#
# Usage (in a .bats file):
#   load '../helpers/mock-bin'   # relative to the .bats file
#
#   @test "example" {
#     mock_bin gh 'echo "$*" >> "$BATS_TEST_TMPDIR/gh-argv.log"'
#     ...
#   }
#
# API:
#   mock_bin <cmd> <script-body>
#     Creates an executable shim named <cmd> in MOCK_BIN_DIR (a single,
#     fixed variable name) and prepends MOCK_BIN_DIR to PATH once per
#     test. <script-body> runs under `#!/usr/bin/env bash` with
#     `set -euo pipefail`; "$@" holds the original arguments.
#     Calling mock_bin again for the same <cmd> replaces the shim.
#
# Cleanup: MOCK_BIN_DIR lives under BATS_TEST_TMPDIR, which bats removes
# automatically after each test — no manual teardown needed. The PATH
# change is confined to the test's own process (each @test runs in its
# own process), so shims never leak between tests.

mock_bin() {
  local cmd="${1:?Usage: mock_bin <cmd> <script-body>}"
  local body="${2:?Usage: mock_bin <cmd> <script-body>}"

  if [[ -z "${MOCK_BIN_DIR:-}" ]]; then
    MOCK_BIN_DIR="${BATS_TEST_TMPDIR:?mock_bin requires bats (BATS_TEST_TMPDIR unset)}/mock-bin"
    mkdir -p "$MOCK_BIN_DIR"
    PATH="${MOCK_BIN_DIR}:${PATH}"
    export PATH MOCK_BIN_DIR
  fi

  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$body" > "${MOCK_BIN_DIR}/${cmd}"
  chmod +x "${MOCK_BIN_DIR}/${cmd}"
}
