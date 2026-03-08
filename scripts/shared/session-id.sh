#!/usr/bin/env bash
# session-id.sh — Generate session ID and derive IPC directory
#
# Usage: source session-id.sh
#
# Environment variables:
#   CEKERNEL_SESSION_ID — Auto-generated as {repo-name}-{random-hex-8} if not set
#   CEKERNEL_IPC_DIR    — Exports /usr/local/var/cekernel/ipc/${CEKERNEL_SESSION_ID}

if [[ -z "${CEKERNEL_SESSION_ID:-}" ]]; then
  # Get repository name (fallback to "cekernel" outside git)
  _repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "cekernel")
  # Random 8-digit hex
  _hex=$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
  export CEKERNEL_SESSION_ID="${_repo_name}-${_hex}"
  unset _repo_name _hex
fi

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}"
export CEKERNEL_IPC_DIR="${CEKERNEL_VAR_DIR}/ipc/${CEKERNEL_SESSION_ID}"
