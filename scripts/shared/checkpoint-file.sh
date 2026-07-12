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
