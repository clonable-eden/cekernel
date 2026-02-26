#!/usr/bin/env bash
# test-trust-registration.sh — claude-json-helper.sh のテスト
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELPER_SCRIPT="${CEKERNEL_DIR}/scripts/shared/claude-json-helper.sh"

echo "test: claude-json-helper.sh"

# ── Setup: テスト用の一時 ~/.claude.json を使う ──
TEST_TMP=$(mktemp -d)
FAKE_CLAUDE_JSON="${TEST_TMP}/claude.json"
trap 'rm -rf "$TEST_TMP"' EXIT

# CLAUDE_JSON を上書きして source する関数
source_helper() {
  (
    export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
    export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"
    source "$HELPER_SCRIPT"
    "$@"
  )
}

# ── Test 1: register_trust — 新規ファイルに全5フィールドが設定される ──
rm -f "$FAKE_CLAUDE_JSON"
source_helper register_trust "/tmp/test-worktree/issue/42-foo"
RESULT=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
assert_eq "register_trust sets hasTrustDialogAccepted" "true" "$RESULT"

RESULT=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasTrustDialogHooksAccepted' "$FAKE_CLAUDE_JSON")
assert_eq "register_trust sets hasTrustDialogHooksAccepted" "true" "$RESULT"

RESULT=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasCompletedProjectOnboarding' "$FAKE_CLAUDE_JSON")
assert_eq "register_trust sets hasCompletedProjectOnboarding" "true" "$RESULT"

RESULT=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasClaudeMdExternalIncludesApproved' "$FAKE_CLAUDE_JSON")
assert_eq "register_trust sets hasClaudeMdExternalIncludesApproved" "true" "$RESULT"

RESULT=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasClaudeMdExternalIncludesWarningShown' "$FAKE_CLAUDE_JSON")
assert_eq "register_trust sets hasClaudeMdExternalIncludesWarningShown" "true" "$RESULT"

# ── Test 2: register_trust — 既存エントリがある場合に他のフィールドが保持される ──
rm -f "$FAKE_CLAUDE_JSON"
cat > "$FAKE_CLAUDE_JSON" <<'JSON'
{
  "projects": {
    "/existing/project": {
      "hasTrustDialogAccepted": true,
      "customField": "keep-me"
    }
  }
}
JSON
source_helper register_trust "/tmp/new-worktree"

RESULT=$(jq -r '.projects["/existing/project"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
assert_eq "existing project trust preserved" "true" "$RESULT"

RESULT=$(jq -r '.projects["/existing/project"].customField' "$FAKE_CLAUDE_JSON")
assert_eq "existing project custom field preserved" "keep-me" "$RESULT"

RESULT=$(jq -r '.projects["/tmp/new-worktree"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
assert_eq "new worktree trust added alongside existing" "true" "$RESULT"

# ── Test 3: unregister_trust — エントリが削除される ──
rm -f "$FAKE_CLAUDE_JSON"
cat > "$FAKE_CLAUDE_JSON" <<'JSON'
{
  "projects": {
    "/tmp/worktree-to-remove": {
      "hasTrustDialogAccepted": true
    },
    "/keep/this/project": {
      "hasTrustDialogAccepted": true
    }
  }
}
JSON
source_helper unregister_trust "/tmp/worktree-to-remove"

RESULT=$(jq -r '.projects["/tmp/worktree-to-remove"] // "null"' "$FAKE_CLAUDE_JSON")
assert_eq "unregister_trust removes target entry" "null" "$RESULT"

RESULT=$(jq -r '.projects["/keep/this/project"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
assert_eq "unregister_trust preserves other entries" "true" "$RESULT"

# ── Test 4: ロック取得・解放 ──
LOCK_TEST_DIR="${TEST_TMP}/claude.json.lock"
rm -rf "$LOCK_TEST_DIR"

# acquire してロックディレクトリが存在する
(
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="$LOCK_TEST_DIR"
  source "$HELPER_SCRIPT"
  acquire_claude_json_lock
  assert_dir_exists "lock directory exists after acquire" "$LOCK_DIR"
  release_claude_json_lock
  assert_not_exists "lock directory removed after release" "$LOCK_DIR"
)

# ── Test 5: register_trust — ~/.claude.json が存在しない場合でも動作する ──
rm -f "$FAKE_CLAUDE_JSON"
source_helper register_trust "/tmp/brand-new"
assert_file_exists "claude.json created when missing" "$FAKE_CLAUDE_JSON"
RESULT=$(jq -r '.projects["/tmp/brand-new"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
assert_eq "trust set on newly created file" "true" "$RESULT"

# ── Test 6: unregister_trust — ファイルが存在しない場合はエラーにならない ──
rm -f "$FAKE_CLAUDE_JSON"
source_helper unregister_trust "/tmp/nonexistent" 2>/dev/null
assert_eq "unregister_trust on missing file exits cleanly" "0" "$?"

report_results
