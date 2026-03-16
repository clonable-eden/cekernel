#!/usr/bin/env bash
# create-checkpoint.sh — Standalone wrapper for create_checkpoint_file
#
# Usage: create-checkpoint.sh <worktree> <phase> <completed> <next> <decisions>
#
# LLM agents running in zsh can call this standalone command without
# sourcing bash-specific scripts directly (avoids zsh "bad substitution"
# errors from bash-specific syntax).
#
# Example:
#   create-checkpoint.sh "$PWD" "Phase 1 (Implementation)" \
#     "tests written, 2/5 files implemented" \
#     "implement remaining 3 files" \
#     "chose approach X because Y"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/checkpoint-file.sh"

WORKTREE="${1:?Usage: create-checkpoint.sh <worktree> <phase> <completed> <next> <decisions>}"
PHASE="${2:?Phase required}"
COMPLETED="${3:-}"
NEXT="${4:-}"
DECISIONS="${5:-}"

create_checkpoint_file "$WORKTREE" "$PHASE" "$COMPLETED" "$NEXT" "$DECISIONS"
