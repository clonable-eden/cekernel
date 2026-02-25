#!/usr/bin/env bash
# test-session-id.sh — session-id.sh のテスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SESSION_SCRIPT="${KERNEL_DIR}/scripts/session-id.sh"

echo "test: session-id.sh"

# ── Test 1: SESSION_ID 未設定時に自動生成される ──
(
  unset SESSION_ID
  unset SESSION_IPC_DIR
  source "$SESSION_SCRIPT"
  assert_eq "SESSION_ID is set when unset" "1" "$([[ -n "${SESSION_ID:-}" ]] && echo 1 || echo 0)"
)

# ── Test 2: 形式が {name}-{hex8} にマッチする ──
(
  unset SESSION_ID
  unset SESSION_IPC_DIR
  source "$SESSION_SCRIPT"
  assert_match "SESSION_ID matches {name}-{hex8}" "^[a-z0-9._-]+-[0-9a-f]{8}$" "$SESSION_ID"
)

# ── Test 3: 既に設定済みの SESSION_ID は上書きされない ──
(
  export SESSION_ID="my-custom-session-abc12345"
  unset SESSION_IPC_DIR
  source "$SESSION_SCRIPT"
  assert_eq "Existing SESSION_ID is preserved" "my-custom-session-abc12345" "$SESSION_ID"
)

# ── Test 4: SESSION_IPC_DIR が正しく導出される ──
(
  export SESSION_ID="test-session-aabbccdd"
  unset SESSION_IPC_DIR
  source "$SESSION_SCRIPT"
  assert_eq "SESSION_IPC_DIR is derived correctly" "/tmp/glimmer-ipc/test-session-aabbccdd" "$SESSION_IPC_DIR"
)

# ── Test 5: SESSION_IPC_DIR — 自動生成時も正しく導出 ──
(
  unset SESSION_ID
  unset SESSION_IPC_DIR
  source "$SESSION_SCRIPT"
  assert_eq "SESSION_IPC_DIR uses generated SESSION_ID" "/tmp/glimmer-ipc/${SESSION_ID}" "$SESSION_IPC_DIR"
)

report_results
