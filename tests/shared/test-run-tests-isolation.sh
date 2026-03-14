#!/usr/bin/env bash
# test-run-tests-isolation.sh — Tests that run-tests.sh does not delete inherited CEKERNEL_VAR_DIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

RUN_TESTS="${SCRIPT_DIR}/../run-tests.sh"

echo "test: run-tests.sh isolation"

# ── Test 1: Pre-existing CEKERNEL_VAR_DIR survives run-tests.sh execution ──
# Copy run-tests.sh to an empty directory (no category dirs → no tests to run)
# so the script finishes instantly, but CEKERNEL_VAR_DIR setup/cleanup still executes.
EMPTY_TEST_DIR="$(mktemp -d)"
cp "$RUN_TESTS" "$EMPTY_TEST_DIR/run-tests.sh"

FAKE_PRODUCTION_DIR="$(mktemp -d)"
touch "${FAKE_PRODUCTION_DIR}/sentinel"

(
  export CEKERNEL_VAR_DIR="$FAKE_PRODUCTION_DIR"
  bash "$EMPTY_TEST_DIR/run-tests.sh"
) >/dev/null 2>&1 || true

assert_dir_exists "inherited CEKERNEL_VAR_DIR survives after run-tests.sh" "$FAKE_PRODUCTION_DIR"
assert_file_exists "files inside inherited dir survive" "${FAKE_PRODUCTION_DIR}/sentinel"

# Cleanup
rm -rf "$FAKE_PRODUCTION_DIR" "$EMPTY_TEST_DIR"

report_results
