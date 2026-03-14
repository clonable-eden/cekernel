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
#   task_file_clear_resume_marker <worktree>    — Remove "## Resume Reason:" section
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

# task_file_clear_resume_marker <worktree>
# Removes the "## Resume Reason: ..." section from the task file.
# This prevents stale resume markers from causing incorrect behavior
# when a Worker is re-spawned after a previous resume cycle.
# No-op if the task file does not exist or has no resume marker.
task_file_clear_resume_marker() {
  local worktree="${1:?Usage: task_file_clear_resume_marker <worktree>}"
  local task_file
  task_file="$(task_file_path "$worktree")"

  [[ -f "$task_file" ]] || return 0

  if grep -q '^## Resume Reason:' "$task_file"; then
    # Remove from "## Resume Reason:" line to end of file,
    # then strip trailing blank lines. Uses a temp file for portability
    # (avoids BSD vs GNU sed -i differences for complex expressions).
    local tmp_file
    tmp_file="$(mktemp)"
    sed '/^## Resume Reason:/,$d' "$task_file" > "$tmp_file"
    # Remove trailing blank lines via awk
    awk '/^[[:space:]]*$/{blank++; next} {for(i=0;i<blank;i++) print ""; blank=0; print}' "$tmp_file" > "$task_file"
    rm -f "$tmp_file"
  fi
}

# create_task_file <worktree> <issue-number>
# Fetches issue data via gh and writes .cekernel-task.md in the worktree
create_task_file() {
  local worktree="${1:?Usage: create_task_file <worktree> <issue-number>}"
  local issue_number="${2:?Usage: create_task_file <worktree> <issue-number>}"
  local task_file
  task_file="$(task_file_path "$worktree")"

  # Fetch issue data as JSON (including comments for full context)
  local issue_json
  issue_json=$(gh issue view "$issue_number" --json title,body,labels,comments)

  # Extract fields
  local title body labels comments_count
  title=$(echo "$issue_json" | jq -r '.title')
  body=$(echo "$issue_json" | jq -r '.body // ""')
  labels=$(echo "$issue_json" | jq -r '(.labels // []) | map(.name) | join(", ")')
  comments_count=$(echo "$issue_json" | jq -r '(.comments // []) | length')

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

    # Append comments section if comments exist
    if [[ "$comments_count" -gt 0 ]]; then
      echo ""
      echo "## Comments"
      echo ""
      echo "$issue_json" | jq -r '
        .comments[] |
        "### @\(.author.login) (\(.createdAt))\n\n\(.body)\n"
      '
    fi
  } > "$task_file"
}
