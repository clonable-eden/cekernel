#!/usr/bin/env bash
# run-tests.sh — Test runner that sequentially executes cekernel/tests/{shared,orchestrator,worker}/test-*.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

echo "=== cekernel test runner ==="
echo ""

for category in shared orchestrator worker; do
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
