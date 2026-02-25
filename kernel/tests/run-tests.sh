#!/usr/bin/env bash
# run-tests.sh — kernel/tests/test-*.sh を順次実行するテストランナー
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

echo "=== kernel test runner ==="
echo ""

for test_file in "${SCRIPT_DIR}"/test-*.sh; do
  [[ -f "$test_file" ]] || continue

  test_name=$(basename "$test_file")
  echo "--- ${test_name} ---"

  if bash "$test_file"; then
    echo "  => OK"
  else
    echo "  => FAILED"
    FAILED_FILES+=("$test_name")
  fi
  echo ""
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
