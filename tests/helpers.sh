#!/usr/bin/env bash
# helpers.sh — Test assertion helpers
#
# Usage: source helpers.sh

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: ${label}"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: ${label}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    ((TESTS_FAILED++)) || true
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "  PASS: ${label}"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: ${label} — file not found: ${path}"
    ((TESTS_FAILED++)) || true
  fi
}

assert_fifo_exists() {
  local label="$1" path="$2"
  if [[ -p "$path" ]]; then
    echo "  PASS: ${label}"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: ${label} — FIFO not found: ${path}"
    ((TESTS_FAILED++)) || true
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "  PASS: ${label}"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: ${label}"
    echo "    pattern: ${pattern}"
    echo "    actual:  ${actual}"
    ((TESTS_FAILED++)) || true
  fi
}

assert_dir_exists() {
  local label="$1" path="$2"
  if [[ -d "$path" ]]; then
    echo "  PASS: ${label}"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: ${label} — directory not found: ${path}"
    ((TESTS_FAILED++)) || true
  fi
}

assert_not_exists() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    echo "  PASS: ${label}"
    ((TESTS_PASSED++)) || true
  else
    echo "  FAIL: ${label} — path should not exist: ${path}"
    ((TESTS_FAILED++)) || true
  fi
}

report_results() {
  echo ""
  echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
  return "$TESTS_FAILED"
}
