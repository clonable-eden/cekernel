#!/usr/bin/env bash
# bare-mode.sh — Explicit-context flag builder for `claude -p --bare` spawns
#
# cekernel 2.0 spawns every `claude -p` process in --bare mode (ADR-0016
# Phase 0, #532). --bare skips hooks, plugin sync, auto-memory, keychain
# reads, and CLAUDE.md auto-discovery, so all required context is injected
# explicitly:
#
#   --bare                       minimal mode (future default for -p)
#   --plugin-dir <cekernel-root> plugin agents/skills resolution
#   --add-dir <context-dir>      CLAUDE.md discovery for worktree/repo root
#   --settings <path>            only when CEKERNEL_CLAUDE_SETTINGS is set
#                                (auth via apiKeyHelper, extra settings)
#
# Usage:
#   source bare-mode.sh
#   bare_mode_preflight || return 1
#   bare_mode_prepare "$worktree"
#   exec claude -p "${CEKERNEL_BARE_FLAGS[@]}" --agent "$name" "$prompt"
#
# Functions:
#   bare_mode_prepare [context-dir]
#     Populates the global CEKERNEL_BARE_FLAGS array (never empty).
#   bare_mode_flags [context-dir]
#     Echoes the flags as a single shell-quoted string, safe to embed in
#     generated runner scripts (runner.sh, wrapper.sh heredocs).
#   bare_mode_preflight
#     Returns 1 with an actionable stderr message when no --bare-compatible
#     auth path exists. --bare never reads OAuth/keychain — auth is strictly
#     ANTHROPIC_API_KEY or apiKeyHelper via --settings. Fail at spawn time
#     instead of launching a process that dies on auth (Rule of Repair).
#
# Environment:
#   CEKERNEL_CLAUDE_SETTINGS — optional path to a Claude settings JSON,
#                              passed via --settings. Required for auth in
#                              environments without ANTHROPIC_API_KEY
#                              (e.g. cron/at, where exported vars don't reach
#                              the generated runner).

# Resolve plugin root at source time (zsh fallback: sourced by backends).
_BARE_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
_BARE_MODE_PLUGIN_ROOT="$(cd "${_BARE_MODE_DIR}/../.." && pwd)"

# bare_mode_prepare [context-dir]
# Populates CEKERNEL_BARE_FLAGS (global array).
bare_mode_prepare() {
  local context_dir="${1:-}"

  CEKERNEL_BARE_FLAGS=(--bare --plugin-dir "$_BARE_MODE_PLUGIN_ROOT")

  if [[ -n "$context_dir" ]]; then
    CEKERNEL_BARE_FLAGS+=(--add-dir "$context_dir")
  fi

  if [[ -n "${CEKERNEL_CLAUDE_SETTINGS:-}" ]]; then
    CEKERNEL_BARE_FLAGS+=(--settings "$CEKERNEL_CLAUDE_SETTINGS")
  fi

  if [[ -n "${CEKERNEL_FALLBACK_MODEL:-}" ]]; then
    CEKERNEL_BARE_FLAGS+=(--fallback-model "$CEKERNEL_FALLBACK_MODEL")
  fi
}

# bare_mode_flags [context-dir]
# Echoes the flag set as one shell-quoted line for heredoc embedding.
bare_mode_flags() {
  bare_mode_prepare "${1:-}"

  local out="" flag
  for flag in "${CEKERNEL_BARE_FLAGS[@]}"; do
    out+="$(printf '%q' "$flag") "
  done
  printf '%s' "${out% }"
}

# bare_mode_preflight
# exit 0 when a --bare-compatible auth path exists, exit 1 otherwise.
bare_mode_preflight() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${CEKERNEL_CLAUDE_SETTINGS:-}" ]]; then
    if [[ ! -f "$CEKERNEL_CLAUDE_SETTINGS" ]]; then
      echo "Error: CEKERNEL_CLAUDE_SETTINGS points to a missing file: ${CEKERNEL_CLAUDE_SETTINGS}" >&2
      return 1
    fi
    return 0
  fi

  cat >&2 <<'EOF'
Error: no --bare-compatible auth available.
claude --bare never reads OAuth/keychain. Set one of:
  - ANTHROPIC_API_KEY  (exported in the spawning environment)
  - CEKERNEL_CLAUDE_SETTINGS  (path to a settings JSON with apiKeyHelper,
    passed to claude via --settings; required for cron/at scheduled jobs)
EOF
  return 1
}
