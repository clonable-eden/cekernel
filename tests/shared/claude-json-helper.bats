#!/usr/bin/env bats
# claude-json-helper.bats — bats-core tests for scripts/shared/claude-json-helper.sh
#
# Verifies register_trust / unregister_trust and lock acquire/release
# behavior using a temp file instead of the real ~/.claude.json.

load '../helpers/assertions'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  HELPER_SCRIPT="${CEKERNEL_DIR}/scripts/shared/claude-json-helper.sh"

  FAKE_CLAUDE_JSON="${BATS_TEST_TMPDIR}/claude.json"
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"
}

# Source the helper in a subshell with overridden CLAUDE_JSON
source_helper() {
  (
    export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
    export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"
    source "$HELPER_SCRIPT"
    "$@"
  )
}

@test "register_trust sets all 5 trust fields on a new file" {
  rm -f "$FAKE_CLAUDE_JSON"
  source_helper register_trust "/tmp/test-worktree/issue/42-foo"

  local result
  result=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
  assert_eq "hasTrustDialogAccepted" "true" "$result"

  result=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasTrustDialogHooksAccepted' "$FAKE_CLAUDE_JSON")
  assert_eq "hasTrustDialogHooksAccepted" "true" "$result"

  result=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasCompletedProjectOnboarding' "$FAKE_CLAUDE_JSON")
  assert_eq "hasCompletedProjectOnboarding" "true" "$result"

  result=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasClaudeMdExternalIncludesApproved' "$FAKE_CLAUDE_JSON")
  assert_eq "hasClaudeMdExternalIncludesApproved" "true" "$result"

  result=$(jq -r '.projects["/tmp/test-worktree/issue/42-foo"].hasClaudeMdExternalIncludesWarningShown' "$FAKE_CLAUDE_JSON")
  assert_eq "hasClaudeMdExternalIncludesWarningShown" "true" "$result"
}

@test "register_trust preserves existing entries when adding new ones" {
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

  local result
  result=$(jq -r '.projects["/existing/project"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
  assert_eq "existing trust preserved" "true" "$result"

  result=$(jq -r '.projects["/existing/project"].customField' "$FAKE_CLAUDE_JSON")
  assert_eq "existing custom field preserved" "keep-me" "$result"

  result=$(jq -r '.projects["/tmp/new-worktree"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
  assert_eq "new worktree trust added" "true" "$result"
}

@test "unregister_trust removes target entry and preserves others" {
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

  local result
  result=$(jq -r '.projects["/tmp/worktree-to-remove"] // "null"' "$FAKE_CLAUDE_JSON")
  assert_eq "target entry removed" "null" "$result"

  result=$(jq -r '.projects["/keep/this/project"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
  assert_eq "other entry preserved" "true" "$result"
}

@test "lock acquire and release" {
  local lock_dir="${BATS_TEST_TMPDIR}/lock-test.lock"
  rm -rf "$lock_dir"

  (
    export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
    export LOCK_DIR="$lock_dir"
    source "$HELPER_SCRIPT"
    acquire_claude_json_lock
    assert_dir_exists "lock directory exists after acquire" "$LOCK_DIR"
    release_claude_json_lock
    assert_not_exists "lock directory removed after release" "$LOCK_DIR"
  )
}

@test "register_trust works when claude.json does not exist" {
  rm -f "$FAKE_CLAUDE_JSON"
  source_helper register_trust "/tmp/brand-new"
  assert_file_exists "claude.json created" "$FAKE_CLAUDE_JSON"

  local result
  result=$(jq -r '.projects["/tmp/brand-new"].hasTrustDialogAccepted' "$FAKE_CLAUDE_JSON")
  assert_eq "trust set on new file" "true" "$result"
}

@test "unregister_trust exits cleanly when file does not exist" {
  rm -f "$FAKE_CLAUDE_JSON"
  run source_helper unregister_trust "/tmp/nonexistent"
  assert_eq "exit 0" "0" "$status"
}
