#!/usr/bin/env bash
# run-tests.sh — Dual-lane test runner (ADR-0017 migration step 1):
#   lane 1: legacy-harness tests/{shared,orchestrator,ctl,process,scheduler}/test-*.sh
#   lane 2: bats-core *.bats files under tests/ (requires bats; brew install bats-core)
# This runner is deleted when the last legacy-harness test-*.sh file is gone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

# Always use a fresh temporary directory for runtime state so tests never affect
# production IPC directories (even when CEKERNEL_VAR_DIR is inherited from the environment)
export CEKERNEL_VAR_DIR="$(mktemp -d)"
_CEKERNEL_VAR_DIR_CREATED=1

echo "=== cekernel test runner ==="
echo ""

for category in shared orchestrator ctl process scheduler; do
  category_dir="${SCRIPT_DIR}/${category}"
  [[ -d "$category_dir" ]] || continue

  echo "=== ${category} ==="
  echo ""

  for test_file in "${category_dir}"/test-*.sh; do
    [[ -f "$test_file" ]] || continue

    test_name="${category}/$(basename "$test_file")"
    echo "--- ${test_name} ---"

    if bash "$test_file"; then
      echo "  => OK"
    else
      echo "  => FAILED"
      FAILED_FILES+=("$test_name")
    fi
    echo ""
  done
done

# ── bats lane ──
BATS_FILE_COUNT=$(find "$SCRIPT_DIR" -name '*.bats' -type f | wc -l | tr -d ' ')
if [[ "$BATS_FILE_COUNT" -gt 0 ]]; then
  echo "=== bats ==="
  echo ""
  if ! command -v bats >/dev/null 2>&1; then
    echo "ERROR: ${BATS_FILE_COUNT} .bats file(s) found but bats is not installed." >&2
    echo "  Install bats-core: brew install bats-core (macOS) or see https://bats-core.readthedocs.io/" >&2
    FAILED_FILES+=("bats (bats-core not installed)")
  elif bats --recursive "$SCRIPT_DIR"; then
    echo "  => OK"
  else
    echo "  => FAILED"
    FAILED_FILES+=("bats")
  fi
  echo ""
fi

# Cleanup test runtime state directory
if [[ "${_CEKERNEL_VAR_DIR_CREATED:-}" == "1" ]]; then
  rm -rf "$CEKERNEL_VAR_DIR"
fi

echo "==========================="
if [[ ${#FAILED_FILES[@]} -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "Failed tests (${#FAILED_FILES[@]}):"
  for f in "${FAILED_FILES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
