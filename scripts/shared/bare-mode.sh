#!/usr/bin/env bash
# bare-mode.sh — Explicit-context flag builder for claude spawns
#
# cekernel 2.0 spawns claude processes in --bare mode when a bare-compatible
# auth path exists (ADR-0016 Phase 0 + Amendment 1, #532/#574). --bare skips
# hooks, plugin sync, auto-memory, keychain reads, and CLAUDE.md
# auto-discovery, so all required context is injected explicitly:
#
#   --bare                       minimal mode — only when a bare-compatible
#                                auth path exists (--bare never reads
#                                OAuth/keychain; Amendment 1)
#   --plugin-dir <cekernel-root> plugin agents/skills resolution
#   --add-dir <context-dir>      CLAUDE.md discovery for worktree/repo root
#   --settings <path>            only when CEKERNEL_CLAUDE_SETTINGS is set
#                                (auth via apiKeyHelper, extra settings)
#   --fallback-model <model>     only when CEKERNEL_FALLBACK_MODEL is set
#                                (auto-fallback when the primary model is
#                                unavailable, e.g. quota exhaustion — #529)
#
# Without a bare-compatible auth path (ANTHROPIC_API_KEY or
# CEKERNEL_CLAUDE_SETTINGS), --bare is dropped so the spawned session
# authenticates via OAuth/keychain — subscription operators are not locked
# out (ADR-0016 Amendment 1). A one-line stderr notice records the branch.
# Context injection (--plugin-dir/--add-dir) is kept on both branches.
#
# Usage (interactive spawn paths — headless.sh, spawn-orchestrator.sh,
# runner.sh; the auth branch is decided inside bare_mode_prepare):
#   source bare-mode.sh
#   bare_mode_prepare "$worktree"
#   exec claude -p "${CEKERNEL_BARE_FLAGS[@]}" --agent "$name" "$prompt"
#
# Usage (scheduled paths — wrapper.sh; unattended, so no-auth is a hard
# error instead of a silent OAuth dependency):
#   source bare-mode.sh
#   bare_mode_preflight || return 1
#   bare_flags="$(bare_mode_flags "$repo")"
#
# Functions:
#   bare_mode_prepare [context-dir]
#     Populates the global CEKERNEL_BARE_FLAGS array (never empty).
#     Includes --bare only when a bare-compatible auth path exists.
#   bare_mode_flags [context-dir]
#     Echoes the flags as a single shell-quoted string, safe to embed in
#     generated runner scripts (runner.sh, wrapper.sh heredocs).
#   bare_mode_preflight
#     Returns 1 with an actionable stderr message when no --bare-compatible
#     auth path exists. Hard gate for scheduled (cron/at) paths only, where
#     silent OAuth expiry is worse than a noisy refusal (Rule of Repair).
#
# Environment:
#   CEKERNEL_CLAUDE_SETTINGS — optional path to a Claude settings JSON,
#                              passed via --settings. Required for auth in
#                              environments without ANTHROPIC_API_KEY
#                              (e.g. cron/at, where exported vars don't reach
#                              the generated runner).
#   CEKERNEL_FALLBACK_MODEL  — optional model name passed via
#                              --fallback-model. Safety valve so Workers keep
#                              running on a smaller model when the primary
#                              model is unavailable. Unset: no flag is added.

# Resolve plugin root at source time (zsh fallback: sourced by backends).
_BARE_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
_BARE_MODE_PLUGIN_ROOT="$(cd "${_BARE_MODE_DIR}/../.." && pwd)"

# _bare_mode_auth_available
# Quiet predicate: exit 0 when a --bare-compatible auth path is configured.
# Presence-only check — a CEKERNEL_CLAUDE_SETTINGS path pointing to a
# missing file stays on the --bare branch, where bare_mode_preflight
# (scheduled paths) or claude itself (--settings) fails noisily instead of
# this module silently falling back to OAuth (Rule of Repair).
_bare_mode_auth_available() {
  [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${CEKERNEL_CLAUDE_SETTINGS:-}" ]]
}

# bare_mode_prepare [context-dir]
# Populates CEKERNEL_BARE_FLAGS (global array). --bare is conditional on
# auth availability (ADR-0016 Amendment 1): without a bare-compatible auth
# path the session authenticates via OAuth/keychain, so --bare (which never
# reads them) is dropped and a one-line notice is emitted on stderr.
bare_mode_prepare() {
  local context_dir="${1:-}"

  if _bare_mode_auth_available; then
    CEKERNEL_BARE_FLAGS=(--bare --plugin-dir "$_BARE_MODE_PLUGIN_ROOT")
  else
    echo "notice: bare mode disabled (no API-key auth); using OAuth" >&2
    CEKERNEL_BARE_FLAGS=(--plugin-dir "$_BARE_MODE_PLUGIN_ROOT")
  fi

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
