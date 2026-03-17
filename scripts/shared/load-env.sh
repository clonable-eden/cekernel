#!/usr/bin/env bash
# load-env.sh — Load env profile for cekernel configuration
#
# Usage: source load-env.sh
#
# Environment variables:
#   CEKERNEL_ENV — Profile name to load (default: "default")
#
# Loading order (lowest to highest priority):
#   1. Script defaults (${VAR:-default} in each script)
#   2. Plugin profile (envs/${CEKERNEL_ENV}.env)
#   3. Project profile (.cekernel/envs/${CEKERNEL_ENV}.env)
#   4. User profile (~/.config/cekernel/envs/${CEKERNEL_ENV}.env)
#   5. Environment variables (explicit export)
#
# Profiles only fill in values that are NOT already set in the environment.
# Explicit user intent (export) always wins over defaults (profile files).
#
# For testing, override search paths via:
#   _CEKERNEL_PLUGIN_ENVS_DIR — Override plugin envs directory
#   _CEKERNEL_PROJECT_ENVS_DIR — Override project envs directory
#   _CEKERNEL_USER_ENVS_DIR — Override user envs directory

CEKERNEL_ENV="${CEKERNEL_ENV:-default}"

_LOAD_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"

# _cekernel_load_env <env-file>
# Reads KEY=VALUE lines from a file, exporting only variables not already set.
# Comments (#) and empty lines are skipped.
_cekernel_load_env() {
  local env_file="$1"
  if [[ -f "$env_file" ]]; then
    while IFS='=' read -r key value; do
      # Skip comments and empty lines
      [[ "$key" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$key" ]] && continue
      # Only set if not already in environment
      # Use printenv for bash/zsh portability (${!key} is bash-only)
      if [[ -z "$(printenv "$key" 2>/dev/null)" ]]; then
        export "$key=$value"
      fi
    done < "$env_file"
  fi
}

# Resolve paths (testable via override variables)
_CEKERNEL_USER_ENVS_DIR="${_CEKERNEL_USER_ENVS_DIR:-${HOME}/.config/cekernel/envs}"
_CEKERNEL_PROJECT_ENVS_DIR="${_CEKERNEL_PROJECT_ENVS_DIR:-.cekernel/envs}"
_CEKERNEL_PLUGIN_ENVS_DIR="${_CEKERNEL_PLUGIN_ENVS_DIR:-${_LOAD_ENV_DIR}/../../envs}"

# Layer 0: User profile (loaded first = highest file priority, fills unset vars)
_cekernel_load_env "${_CEKERNEL_USER_ENVS_DIR}/${CEKERNEL_ENV}.env"

# Layer 1: Project override (fills remaining unset vars)
_cekernel_load_env "${_CEKERNEL_PROJECT_ENVS_DIR}/${CEKERNEL_ENV}.env"

# Layer 2: Plugin defaults (fills remaining unset vars)
_cekernel_load_env "${_CEKERNEL_PLUGIN_ENVS_DIR}/${CEKERNEL_ENV}.env"
