#!/usr/bin/env bats
# task-file.bats — bats-core tests for scripts/shared/task-file.sh
#
# Covers the cross-repo `repo` argument of create_task_file (#440):
# recorded gh argv (ADR-0017: executed effects, not generated text) and
# the `repo:` frontmatter field. Legacy coverage for the repo-less
# behavior lives in tests/shared/test-task-file.sh.

load '../helpers/assertions'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORKTREE="${BATS_TEST_TMPDIR}/worktree"
  mkdir -p "$WORKTREE"
  GH_ARGV_LOG="${BATS_TEST_TMPDIR}/gh-argv.log"
}

# mock_gh_issue — PATH-shim gh that records argv and returns canned issue JSON
mock_gh_issue() {
  mock_bin gh "printf '%s\n' \"\$*\" >> \"${GH_ARGV_LOG}\"
cat <<'JSON'
{\"title\":\"feat: cross repo issue\",\"body\":\"issue body\",\"labels\":[{\"name\":\"enhancement\"}],\"comments\":[]}
JSON"
}

@test "create_task_file with repo arg passes --repo to gh" {
  mock_gh_issue
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

  create_task_file "$WORKTREE" 42 "acme/planning"

  assert_file_exists "gh argv recorded" "$GH_ARGV_LOG"
  assert_match "gh argv contains --repo owner/repo" \
    "--repo acme/planning" "$(cat "$GH_ARGV_LOG")"
}

@test "create_task_file with repo arg writes repo: field to frontmatter" {
  mock_gh_issue
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

  create_task_file "$WORKTREE" 42 "acme/planning"

  assert_file_exists "task file created" "${WORKTREE}/.cekernel-task.md"
  assert_match "frontmatter has repo field" \
    "repo: acme/planning" "$(cat "${WORKTREE}/.cekernel-task.md")"
}

@test "create_task_file without repo arg omits --repo and repo: field" {
  mock_gh_issue
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

  create_task_file "$WORKTREE" 42

  local gh_argv content
  gh_argv="$(cat "$GH_ARGV_LOG")"
  content="$(cat "${WORKTREE}/.cekernel-task.md")"
  if [[ "$gh_argv" == *"--repo"* ]]; then
    echo "FAIL: --repo must not appear without repo arg: ${gh_argv}" >&2
    return 1
  fi
  if [[ "$content" == *"repo:"* ]]; then
    echo "FAIL: repo: field must not appear without repo arg" >&2
    return 1
  fi
  assert_match "task file still has issue number" "issue: 42" "$content"
}

@test "create_task_file with empty repo arg behaves like no repo arg" {
  mock_gh_issue
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

  create_task_file "$WORKTREE" 42 ""

  local gh_argv
  gh_argv="$(cat "$GH_ARGV_LOG")"
  if [[ "$gh_argv" == *"--repo"* ]]; then
    echo "FAIL: --repo must not appear with empty repo arg: ${gh_argv}" >&2
    return 1
  fi
}

# ── Base branch propagation (#562) ──

@test "create_task_file with base arg writes base: field to frontmatter" {
  mock_gh_issue
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

  create_task_file "$WORKTREE" 42 "" "2.0-dev"

  assert_file_exists "task file created" "${WORKTREE}/.cekernel-task.md"
  assert_match "frontmatter has base field" \
    "base: 2.0-dev" "$(cat "${WORKTREE}/.cekernel-task.md")"
}

@test "create_task_file with repo and base args writes both fields" {
  mock_gh_issue
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

  create_task_file "$WORKTREE" 42 "acme/planning" "2.0-dev"

  local content
  content="$(cat "${WORKTREE}/.cekernel-task.md")"
  assert_match "frontmatter has repo field" "repo: acme/planning" "$content"
  assert_match "frontmatter has base field" "base: 2.0-dev" "$content"
}

@test "create_task_file without base arg omits base: field" {
  mock_gh_issue
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"

  create_task_file "$WORKTREE" 42

  local content
  content="$(cat "${WORKTREE}/.cekernel-task.md")"
  if [[ "$content" == *"base:"* ]]; then
    echo "FAIL: base: field must not appear without base arg" >&2
    return 1
  fi
  assert_match "task file still has issue number" "issue: 42" "$content"
}
