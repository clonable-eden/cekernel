#!/usr/bin/env bash
# task-file.sh — Local task file helpers for session memory layer
#
# Extracts issue data from GitHub into a local .cekernel-task.md file
# in the worktree at spawn time. Workers read locally instead of calling
# `gh issue view`, reducing GitHub API calls and context window consumption.
#
# Usage: source task-file.sh
#
# Functions:
#   create_task_file <worktree> <issue-number>  — Fetch issue and write .cekernel-task.md
#   task_file_path <worktree>                   — Return the task file path
#   task_file_exists <worktree>                 — Check if the task file exists (exit 0/1)
#
# OS Analogy:
#   Page cache — GitHub API response cached as a local file

CEKERNEL_TASK_FILENAME="${CEKERNEL_TASK_FILENAME:-.cekernel-task.md}"

# task_file_path <worktree>
# Returns the absolute path to the task file
task_file_path() {
  local worktree="${1:?Usage: task_file_path <worktree>}"
  echo "${worktree}/${CEKERNEL_TASK_FILENAME}"
}

# task_file_exists <worktree>
# Returns 0 if the task file exists, 1 otherwise
task_file_exists() {
  local worktree="${1:?Usage: task_file_exists <worktree>}"
  [[ -f "$(task_file_path "$worktree")" ]]
}

# create_task_file <worktree> <issue-number>
# Fetches issue data via gh and writes .cekernel-task.md in the worktree
create_task_file() {
  local worktree="${1:?Usage: create_task_file <worktree> <issue-number>}"
  local issue_number="${2:?Usage: create_task_file <worktree> <issue-number>}"
  local task_file
  task_file="$(task_file_path "$worktree")"

  # Fetch issue data as JSON
  local issue_json
  issue_json=$(gh issue view "$issue_number" --json title,body,labels)

  # Extract fields
  local title body labels
  title=$(echo "$issue_json" | jq -r '.title')
  body=$(echo "$issue_json" | jq -r '.body // ""')
  labels=$(echo "$issue_json" | jq -r '(.labels // []) | map(.name) | join(", ")')

  # Write task file
  {
    echo "---"
    echo "issue: ${issue_number}"
    echo "title: \"${title}\""
    if [[ -n "$labels" ]]; then
      echo "labels: [${labels}]"
    else
      echo "labels: []"
    fi
    echo "---"
    echo ""
    if [[ -n "$body" ]]; then
      echo "$body"
    fi
  } > "$task_file"
}
