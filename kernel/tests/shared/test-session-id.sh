#!/usr/bin/env bash
# test-session-id.sh — session-id.sh のテスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SESSION_SCRIPT="${KERNEL_DIR}/scripts/shared/session-id.sh"

echo "test: session-id.sh"

# ── Test 1: SESSION_ID 未設定時に自動生成される ──
RESULT=$(unset SESSION_ID; unset SESSION_IPC_DIR; source "$SESSION_SCRIPT"; echo "$SESSION_ID")
assert_eq "SESSION_ID is generated when unset" "1" "$([[ -n "$RESULT" ]] && echo 1 || echo 0)"

# ── Test 2: 形式が {name}-{hex8} にマッチする ──
RESULT=$(unset SESSION_ID; unset SESSION_IPC_DIR; source "$SESSION_SCRIPT"; echo "$SESSION_ID")
assert_match "SESSION_ID matches {name}-{hex8}" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$RESULT"

# ── Test 3: 既に設定済みの SESSION_ID は上書きされない ──
RESULT=$(export SESSION_ID="my-custom-session-abc12345"; unset SESSION_IPC_DIR; source "$SESSION_SCRIPT"; echo "$SESSION_ID")
assert_eq "Existing SESSION_ID is preserved" "my-custom-session-abc12345" "$RESULT"

# ── Test 4: SESSION_IPC_DIR が正しく導出される ──
RESULT=$(export SESSION_ID="test-session-aabbccdd"; unset SESSION_IPC_DIR; source "$SESSION_SCRIPT"; echo "$SESSION_IPC_DIR")
assert_eq "SESSION_IPC_DIR is derived correctly" "/tmp/glimmer-ipc/test-session-aabbccdd" "$RESULT"

# ── Test 5: SESSION_IPC_DIR — 自動生成時も正しく導出 ──
RESULT=$(unset SESSION_ID; unset SESSION_IPC_DIR; source "$SESSION_SCRIPT"; echo "${SESSION_IPC_DIR}|${SESSION_ID}")
IPC_DIR="${RESULT%|*}"
SID="${RESULT#*|}"
assert_eq "SESSION_IPC_DIR uses generated SESSION_ID" "/tmp/glimmer-ipc/${SID}" "$IPC_DIR"

report_results
