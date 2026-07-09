#!/usr/bin/env bash
# session-id.sh — Generate session ID and derive IPC directory
#
# Usage: source session-id.sh
#
# Resolution order for CEKERNEL_SESSION_ID:
#   1. Already set in environment → use as-is
#   2. .cekernel-env exists at git toplevel → read provisioned ID (#629)
#   3. Generate new ID as {repo-name}-{random-hex-8}
#
# Environment variables (exported):
#   CEKERNEL_SESSION_ID — Session identifier
#   CEKERNEL_IPC_DIR    — $HOME/.local/var/cekernel/ipc/${CEKERNEL_SESSION_ID}

if [[ -z "${CEKERNEL_SESSION_ID:-}" ]]; then
  _cekernel_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || true

  # Check for .cekernel-env provisioned by spawn.sh (Worker worktree context).
  # Shell state doesn't persist between Claude Code Bash tool calls, so
  # reading the provisioned ID prevents incorrect re-derivation from the
  # worktree directory name (#629).
  _cekernel_env_file="${_cekernel_toplevel:+${_cekernel_toplevel}/.cekernel-env}"
  if [[ -n "${_cekernel_env_file:-}" && -f "$_cekernel_env_file" ]]; then
    _provisioned_id=$(grep '^export CEKERNEL_SESSION_ID=' "$_cekernel_env_file" 2>/dev/null | head -1 | sed 's/^export CEKERNEL_SESSION_ID=//')
    if [[ -n "${_provisioned_id:-}" ]]; then
      export CEKERNEL_SESSION_ID="$_provisioned_id"
    fi
    unset _provisioned_id
  fi
  unset _cekernel_env_file

  # Fallback: generate a new session ID (Orchestrator or non-worktree context)
  if [[ -z "${CEKERNEL_SESSION_ID:-}" ]]; then
    _repo_name=$(basename "${_cekernel_toplevel:-cekernel}" 2>/dev/null || echo "cekernel")
    _hex=$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
    export CEKERNEL_SESSION_ID="${_repo_name}-${_hex}"
    unset _repo_name _hex
  fi
  unset _cekernel_toplevel
fi

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
export CEKERNEL_IPC_DIR="${CEKERNEL_VAR_DIR}/ipc/${CEKERNEL_SESSION_ID}"
