#!/usr/bin/env bash
# checkpoint-file.sh — Checkpoint file helpers for context swap (suspend/resume)
#
# Workers save progress to a .cekernel-checkpoint.md file before suspending.
# When a new Worker is spawned with --resume, it reads this checkpoint to
# continue where the previous Worker left off.
#
# Usage: source checkpoint-file.sh
#
# Functions:
#   create_checkpoint_file <worktree> <phase> <completed> <next> <decisions>
#   checkpoint_file_path <worktree>          — Return the checkpoint file path
#   checkpoint_file_exists <worktree>        — Check if the checkpoint file exists (exit 0/1)
#   read_checkpoint_file <worktree>          — Read checkpoint as JSON
#
# OS Analogy:
#   Hibernate — save process state to disk for later resume

CEKERNEL_CHECKPOINT_FILENAME="${CEKERNEL_CHECKPOINT_FILENAME:-.cekernel-checkpoint.md}"

# checkpoint_file_path <worktree>
# Returns the absolute path to the checkpoint file
checkpoint_file_path() {
  local worktree="${1:?Usage: checkpoint_file_path <worktree>}"
  echo "${worktree}/${CEKERNEL_CHECKPOINT_FILENAME}"
}

# checkpoint_file_exists <worktree>
# Returns 0 if the checkpoint file exists, 1 otherwise
checkpoint_file_exists() {
  local worktree="${1:?Usage: checkpoint_file_exists <worktree>}"
  [[ -f "$(checkpoint_file_path "$worktree")" ]]
}

# create_checkpoint_file <worktree> <phase> <completed> <next> <decisions>
# Writes .cekernel-checkpoint.md in the worktree
create_checkpoint_file() {
  local worktree="${1:?Usage: create_checkpoint_file <worktree> <phase> <completed> <next> <decisions>}"
  local phase="${2:?Phase required}"
  local completed="${3:-}"
  local next="${4:-}"
  local decisions="${5:-}"
  local checkpoint_file
  checkpoint_file="$(checkpoint_file_path "$worktree")"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  {
    echo "# Checkpoint"
    echo ""
    echo "- **Current phase**: ${phase}"
    echo "- **Completed**: ${completed}"
    echo "- **Next**: ${next}"
    echo "- **Key decisions**: ${decisions}"
    echo "- **Timestamp**: ${timestamp}"
  } > "$checkpoint_file"
}

# read_checkpoint_file <worktree>
# Reads checkpoint file and outputs JSON
# Returns {"exists": false} if no checkpoint file exists
read_checkpoint_file() {
  local worktree="${1:?Usage: read_checkpoint_file <worktree>}"
  local checkpoint_file
  checkpoint_file="$(checkpoint_file_path "$worktree")"

  if [[ ! -f "$checkpoint_file" ]]; then
    jq -cn '{exists: false}'
    return 0
  fi

  local content
  content=$(cat "$checkpoint_file")

  # Parse markdown fields
  local phase completed next decisions timestamp
  phase=$(echo "$content" | sed -n 's/^- \*\*Current phase\*\*: //p')
  completed=$(echo "$content" | sed -n 's/^- \*\*Completed\*\*: //p')
  next=$(echo "$content" | sed -n 's/^- \*\*Next\*\*: //p')
  decisions=$(echo "$content" | sed -n 's/^- \*\*Key decisions\*\*: //p')
  timestamp=$(echo "$content" | sed -n 's/^- \*\*Timestamp\*\*: //p')

  jq -cn \
    --arg phase "$phase" \
    --arg completed "$completed" \
    --arg next "$next" \
    --arg decisions "$decisions" \
    --arg timestamp "$timestamp" \
    '{exists: true, phase: $phase, completed: $completed, next: $next, decisions: $decisions, timestamp: $timestamp}'
}
