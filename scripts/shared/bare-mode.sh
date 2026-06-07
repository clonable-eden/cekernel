#!/usr/bin/env bash
# bare-mode.sh — Build `claude --bare` flag set for spawn paths
#
# Usage:
#   source bare-mode.sh
#   cekernel_bare_prepare [worktree_root]
#   exec claude "${CEKERNEL_BARE_FLAGS[@]}" -p --agent "$name" "$prompt"
#
# Functions:
#   cekernel_use_bare        — exit 0 if CEKERNEL_USE_BARE=1, else exit 1
#   cekernel_bare_prepare    — populate global CEKERNEL_BARE_FLAGS array
#                              with the flags required when --bare is enabled
#
# Output:
#   CEKERNEL_BARE_FLAGS (array) — flags to inject before the prompt.
#                                 Empty when CEKERNEL_USE_BARE is unset/0.
#
# Environment:
#   CEKERNEL_USE_BARE — "1" to enable; anything else (or unset) keeps the
#                       existing `claude -p` behavior (default: 0).
#
# Auth note:
#   --bare does not read OAuth/keychain. ANTHROPIC_API_KEY or apiKeyHelper
#   (via --settings) is required when CEKERNEL_USE_BARE=1.

cekernel_use_bare() {
  [[ "${CEKERNEL_USE_BARE:-0}" == "1" ]]
}

cekernel_bare_prepare() {
  CEKERNEL_BARE_FLAGS=()

  cekernel_use_bare || return 0

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
  local plugin_root
  plugin_root="$(cd "${script_dir}/../.." && pwd)"

  CEKERNEL_BARE_FLAGS=(--bare --plugin-dir "$plugin_root")

  local worktree="${1:-}"
  if [[ -n "$worktree" ]]; then
    CEKERNEL_BARE_FLAGS+=(--add-dir "$worktree")
  fi
}
