#!/usr/bin/env bats
# task-file.bats — bats-core tests for scripts/shared/task-file.sh
#
# Covers the cross-repo `repo` argument of create_task_file (#440),
# base branch propagation (#562), and task_file_clear_resume_marker.
# Recorded gh argv (ADR-0017: executed effects, not generated text).

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

# ── task_file_clear_resume_marker ──

@test "task_file_clear_resume_marker removes resume marker section" {
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"
  cat > "${WORKTREE}/.cekernel-task.md" <<'TASK'
---
issue: 100
title: "test issue"
labels: [enhancement]
---

Issue body content here.

## Resume Reason: changes-requested

Review comments are on PR #50. Read them with `gh pr view 50 --comments`.
TASK

  task_file_clear_resume_marker "$WORKTREE"
  local content
  content="$(cat "${WORKTREE}/.cekernel-task.md")"
  if [[ "$content" == *"Resume Reason"* ]]; then
    echo "FAIL: resume marker should be removed" >&2
    return 1
  fi
  assert_match "original content preserved" "Issue body content here" "$content"
}

@test "task_file_clear_resume_marker is no-op when no marker exists" {
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"
  cat > "${WORKTREE}/.cekernel-task.md" <<'TASK'
---
issue: 101
title: "test issue without marker"
labels: []
---

Just a normal task file.
TASK

  local before after
  before="$(cat "${WORKTREE}/.cekernel-task.md")"
  task_file_clear_resume_marker "$WORKTREE"
  after="$(cat "${WORKTREE}/.cekernel-task.md")"
  assert_eq "content unchanged" "$before" "$after"
}

@test "task_file_clear_resume_marker exits cleanly when no task file" {
  source "${CEKERNEL_DIR}/scripts/shared/task-file.sh"
  local empty_wt="${BATS_TEST_TMPDIR}/empty-wt"
  mkdir -p "$empty_wt"
  run task_file_clear_resume_marker "$empty_wt"
  assert_eq "exits 0" "0" "$status"
}
