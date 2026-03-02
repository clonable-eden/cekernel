#!/usr/bin/env bash
# test-session-id.sh — Tests for session-id.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SESSION_SCRIPT="${CEKERNEL_DIR}/scripts/shared/session-id.sh"

echo "test: session-id.sh"

# ── Test 1: Auto-generated when CEKERNEL_SESSION_ID is not set ──
RESULT=$(unset CEKERNEL_SESSION_ID; unset CEKERNEL_IPC_DIR; source "$SESSION_SCRIPT"; echo "$CEKERNEL_SESSION_ID")
assert_eq "CEKERNEL_SESSION_ID is generated when unset" "1" "$([[ -n "$RESULT" ]] && echo 1 || echo 0)"

# ── Test 2: Format matches {name}-{hex8} ──
RESULT=$(unset CEKERNEL_SESSION_ID; unset CEKERNEL_IPC_DIR; source "$SESSION_SCRIPT"; echo "$CEKERNEL_SESSION_ID")
assert_match "CEKERNEL_SESSION_ID matches {name}-{hex8}" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$RESULT"

# ── Test 3: Existing CEKERNEL_SESSION_ID is not overwritten ──
RESULT=$(export CEKERNEL_SESSION_ID="my-custom-session-abc12345"; unset CEKERNEL_IPC_DIR; source "$SESSION_SCRIPT"; echo "$CEKERNEL_SESSION_ID")
assert_eq "Existing CEKERNEL_SESSION_ID is preserved" "my-custom-session-abc12345" "$RESULT"

# ── Test 4: CEKERNEL_IPC_DIR is correctly derived ──
RESULT=$(export CEKERNEL_SESSION_ID="test-session-aabbccdd"; unset CEKERNEL_IPC_DIR; source "$SESSION_SCRIPT"; echo "$CEKERNEL_IPC_DIR")
assert_eq "CEKERNEL_IPC_DIR is derived correctly" "/tmp/cekernel-ipc/test-session-aabbccdd" "$RESULT"

# ── Test 5: CEKERNEL_IPC_DIR — correctly derived with auto-generated ID ──
RESULT=$(unset CEKERNEL_SESSION_ID; unset CEKERNEL_IPC_DIR; source "$SESSION_SCRIPT"; echo "${CEKERNEL_IPC_DIR}|${CEKERNEL_SESSION_ID}")
IPC_DIR="${RESULT%|*}"
SID="${RESULT#*|}"
assert_eq "CEKERNEL_IPC_DIR uses generated CEKERNEL_SESSION_ID" "/tmp/cekernel-ipc/${SID}" "$IPC_DIR"

report_results
