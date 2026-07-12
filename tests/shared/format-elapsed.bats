#!/usr/bin/env bats
# format-elapsed.bats — tests for scripts/shared/format-elapsed.sh
#
# format_elapsed renders elapsed seconds as a compact h/m/s string
# (shared by orchctl.sh ls/ps and process-status.sh).

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${CEKERNEL_DIR}/scripts/shared/format-elapsed.sh"
}

@test "format_elapsed renders seconds below one minute" {
  run format_elapsed 0
  assert_eq "zero" "0s" "$output"
  run format_elapsed 59
  assert_eq "boundary 59" "59s" "$output"
}

@test "format_elapsed renders whole minutes from 60s up to an hour" {
  run format_elapsed 60
  assert_eq "boundary 60" "1m" "$output"
  run format_elapsed 3599
  assert_eq "boundary 3599" "59m" "$output"
}

@test "format_elapsed renders hours and minutes from 3600s" {
  run format_elapsed 3600
  assert_eq "boundary 3600" "1h0m" "$output"
  run format_elapsed 7260
  assert_eq "2h1m" "2h1m" "$output"
}
