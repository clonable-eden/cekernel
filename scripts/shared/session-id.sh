#!/usr/bin/env bash
# session-id.sh — Generate session ID and derive IPC directory
#
# Usage: source session-id.sh
#
# Environment variables:
#   CEKERNEL_SESSION_ID — Auto-generated as {repo-name}-{random-hex-8} if not set
#   CEKERNEL_IPC_DIR    — Exports $HOME/.local/var/cekernel/ipc/${CEKERNEL_SESSION_ID}

if [[ -z "${CEKERNEL_SESSION_ID:-}" ]]; then
  # Check for .cekernel-env provisioned by spawn.sh (Worker worktree context).
  # When a Worker's process scripts source session-id.sh without
  # CEKERNEL_SESSION_ID in the environment (shell state doesn't persist
  # between Bash tool calls), reading the provisioned ID prevents incorrect
  # re-derivation from the worktree directory name (#629).
  _cekernel_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || true
  _cekernel_env_file="${_cekernel_toplevel:+${_cekernel_toplevel}/.cekernel-env}"
  if [[ -n "${_cekernel_env_file:-}" && -f "$_cekernel_env_file" ]]; then
    _provisioned_id=$(grep '^export CEKERNEL_SESSION_ID=' "$_cekernel_env_file" 2>/dev/null | head -1 | sed 's/^export CEKERNEL_SESSION_ID=//')
    if [[ -n "${_provisioned_id:-}" ]]; then
      export CEKERNEL_SESSION_ID="$_provisioned_id"
    fi
    unset _provisioned_id
  fi
  unset _cekernel_toplevel _cekernel_env_file

  # Fallback: generate a new session ID (Orchestrator or non-worktree context)
  if [[ -z "${CEKERNEL_SESSION_ID:-}" ]]; then
    _repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "cekernel")
    _hex=$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
    export CEKERNEL_SESSION_ID="${_repo_name}-${_hex}"
    unset _repo_name _hex
  fi
fi

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
export CEKERNEL_IPC_DIR="${CEKERNEL_VAR_DIR}/ipc/${CEKERNEL_SESSION_ID}"
