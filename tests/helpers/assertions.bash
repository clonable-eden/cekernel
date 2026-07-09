# assertions.bash — bats-core assertion helpers (ADR-0017 Decision 1)
#
# bats-assert is intentionally NOT vendored; these helpers plus plain
# bash conditionals cover current needs.
#
# On failure they print a diagnostic to stderr and return 1, which fails
# the surrounding @test immediately (bats runs under set -e semantics
# per test).
#
# Usage (in a .bats file):
#   load ../helpers/assertions   # relative to the .bats file
#
# API:
#   assert_eq <label> <expected> <actual>     — exact string equality
#   assert_match <label> <regex> <actual>     — bash [[ =~ ]] regex match
#   assert_file_exists <label> <path>         — path is a regular file
#   assert_dir_exists <label> <path>          — path is a directory
#   assert_not_exists <label> <path>          — path does not exist
#   wait_for_file <path> [max_attempts]       — poll (0.1s) until file exists

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    return 0
  fi
  echo "FAIL: ${label}" >&2
  echo "  expected: ${expected}" >&2
  echo "  actual:   ${actual}" >&2
  return 1
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    return 0
  fi
  echo "FAIL: ${label}" >&2
  echo "  pattern: ${pattern}" >&2
  echo "  actual:  ${actual}" >&2
  return 1
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    return 0
  fi
  echo "FAIL: ${label} — file not found: ${path}" >&2
  return 1
}

assert_dir_exists() {
  local label="$1" path="$2"
  if [[ -d "$path" ]]; then
    return 0
  fi
  echo "FAIL: ${label} — directory not found: ${path}" >&2
  return 1
}

assert_not_exists() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  echo "FAIL: ${label} — path should not exist: ${path}" >&2
  return 1
}

wait_for_file() {
  local file="$1"
  local max_attempts="${2:-30}"
  local i
  for i in $(seq 1 "$max_attempts"); do
    [[ -f "$file" ]] && return 0
    sleep 0.1
  done
  return 1
}
