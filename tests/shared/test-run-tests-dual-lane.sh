#!/usr/bin/env bash
# test-run-tests-dual-lane.sh — Tests that run-tests.sh runs both lanes:
# legacy-harness test-*.sh and bats *.bats (ADR-0017 migration step 1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

RUN_TESTS="${SCRIPT_DIR}/../run-tests.sh"

echo "test: run-tests.sh dual-lane"

# ── Setup: copy run-tests.sh into a sandbox with synthetic test dirs ──
# bats is mocked via PATH shim so the test does not require bats-core installed.
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  cp "$RUN_TESTS" "${SANDBOX}/run-tests.sh"
  mkdir -p "${SANDBOX}/shared"

  # PATH shim for bats: records argv, exit code controlled by BATS_SHIM_EXIT
  SHIM_DIR="${SANDBOX}/shim-bin"
  mkdir -p "$SHIM_DIR"
  cat > "${SHIM_DIR}/bats" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${SANDBOX}/bats-argv.log"
exit "\${BATS_SHIM_EXIT:-0}"
EOF
  chmod +x "${SHIM_DIR}/bats"
}

# ── Test 1: legacy lane and bats lane both run in one invocation ──
setup_sandbox
echo 'echo "legacy ran" > "$(dirname "$0")/../legacy-ran.txt"' > "${SANDBOX}/shared/test-legacy.sh"
echo '@test "sample" { true; }' > "${SANDBOX}/shared/sample.bats"

EXIT=0
(
  export PATH="${SHIM_DIR}:${PATH}"
  bash "${SANDBOX}/run-tests.sh"
) >/dev/null 2>&1 || EXIT=$?

assert_eq "dual-lane run exits 0 when both lanes pass" "0" "$EXIT"
assert_file_exists "legacy lane executed test-*.sh" "${SANDBOX}/legacy-ran.txt"
assert_file_exists "bats lane invoked bats" "${SANDBOX}/bats-argv.log"
assert_match "bats invoked against tests dir or .bats files" "(${SANDBOX}|sample\.bats)" "$(cat "${SANDBOX}/bats-argv.log" 2>/dev/null || echo '')"
rm -rf "$SANDBOX"

# ── Test 2: bats lane failure makes run-tests.sh exit non-zero ──
setup_sandbox
echo '@test "failing" { false; }' > "${SANDBOX}/shared/failing.bats"

EXIT=0
(
  export PATH="${SHIM_DIR}:${PATH}"
  export BATS_SHIM_EXIT=1
  bash "${SANDBOX}/run-tests.sh"
) >/dev/null 2>&1 || EXIT=$?

assert_eq "bats lane failure propagates to exit code" "1" "$([[ "$EXIT" -ne 0 ]] && echo 1 || echo 0)"
rm -rf "$SANDBOX"

# ── Test 3: no .bats files → bats lane skipped, exit 0 ──
setup_sandbox
echo 'true' > "${SANDBOX}/shared/test-noop.sh"

EXIT=0
(
  export PATH="${SHIM_DIR}:${PATH}"
  bash "${SANDBOX}/run-tests.sh"
) >/dev/null 2>&1 || EXIT=$?

assert_eq "runner exits 0 with no .bats files" "0" "$EXIT"
assert_not_exists "bats not invoked when no .bats files exist" "${SANDBOX}/bats-argv.log"
rm -rf "$SANDBOX"

# ── Test 4: .bats files exist but bats not installed → fail noisily ──
setup_sandbox
rm -rf "$SHIM_DIR"  # no bats shim on PATH
echo '@test "sample" { true; }' > "${SANDBOX}/shared/sample.bats"

EXIT=0
OUTPUT=$(
  # Hide any real bats by restricting PATH to a dir with only required tools
  TOOLS_DIR="${SANDBOX}/tools-bin"
  mkdir -p "$TOOLS_DIR"
  for tool in bash mktemp rm find sort dirname basename cat echo wc tr; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -s "$tool_path" "${TOOLS_DIR}/${tool}" 2>/dev/null || true
  done
  export PATH="$TOOLS_DIR"
  bash "${SANDBOX}/run-tests.sh" 2>&1
) || EXIT=$?

assert_eq "runner fails when .bats exist but bats missing" "1" "$([[ "$EXIT" -ne 0 ]] && echo 1 || echo 0)"
assert_match "error message mentions bats-core install" "bats-core" "$OUTPUT"
rm -rf "$SANDBOX"

report_results
