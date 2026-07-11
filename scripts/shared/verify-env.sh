#!/usr/bin/env bash
# verify-env.sh — Validate required CEKERNEL_* environment variables
#
# Usage: verify-env.sh
#
# Checks that required CEKERNEL_* vars are non-empty and that
# spawn-worker.sh is on PATH. Exits 1 with a descriptive error on
# any failure; exits 0 silently on success (Rule of Silence).
#
# Intended to be called after sourcing ${CEKERNEL_IPC_DIR}/env.sh
# to catch env delivery failures early (fail-loud, Rule of Repair).
#
# Required variables:
#   CEKERNEL_SESSION_ID — Session identifier
#   CEKERNEL_IPC_DIR    — IPC directory path
#   CEKERNEL_ENV        — Environment profile name
#
# PATH check:
#   spawn-worker.sh must be resolvable via `command -v`
set -euo pipefail

ERRORS=()

# ── Required variables ──
for var in CEKERNEL_SESSION_ID CEKERNEL_IPC_DIR CEKERNEL_ENV; do
  val="${!var:-}"
  if [[ -z "$val" ]]; then
    ERRORS+=("${var} is not set or empty")
  fi
done

# ── PATH check ──
if ! command -v spawn-worker.sh >/dev/null 2>&1; then
  ERRORS+=("spawn-worker.sh not found on PATH")
fi

# ── Report ──
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "verify-env: environment validation failed:" >&2
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}" >&2
  done
  exit 1
fi
