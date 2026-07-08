# session.bash — per-test unique CEKERNEL_SESSION_ID helper (ADR-0017)
#
# Derives a session ID from BATS_TEST_FILENAME + BATS_TEST_NAME so that
# every @test gets its own IPC directory. This prevents collisions under
# parallel bats runs (`bats --jobs N`) and overrides any session scope
# inherited from the invoking environment (e.g. a Worker's .cekernel-env).
#
# Usage (in a .bats file):
#   load '../helpers/session'   # relative to the .bats file
#
#   setup() {
#     set_test_session_id
#     source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
#     rm -rf "$CEKERNEL_IPC_DIR" && mkdir -p "$CEKERNEL_IPC_DIR"
#   }
#
# API:
#   test_session_id
#     Prints the derived ID: bats-{file-slug}-{hex8}. The hex8 suffix is
#     a hash of BATS_TEST_FILENAME:BATS_TEST_NAME — deterministic for
#     the same test, distinct across tests.
#
#   set_test_session_id
#     Exports CEKERNEL_SESSION_ID (via test_session_id) and unsets any
#     inherited CEKERNEL_IPC_DIR so session-id.sh re-derives a per-test
#     IPC directory.

test_session_id() {
  local name hash
  name=$(basename "${BATS_TEST_FILENAME:-unknown}" .bats \
    | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')
  name="${name%-}"
  hash=$(printf '%s' "${BATS_TEST_FILENAME:-}:${BATS_TEST_NAME:-}" \
    | shasum | cut -c1-8)
  echo "bats-${name}-${hash}"
}

set_test_session_id() {
  CEKERNEL_SESSION_ID="$(test_session_id)"
  export CEKERNEL_SESSION_ID
  unset CEKERNEL_IPC_DIR
}
