#!/usr/bin/env bash
# resolve-api-key.sh — Resolve ANTHROPIC_API_KEY dynamically
#
# Usage: bash resolve-api-key.sh
#   Outputs the API key to stdout.
#   Exit 1 if no key can be resolved.
#
# Resolution order:
#   1. ANTHROPIC_API_KEY environment variable (if non-empty)
#   2. macOS Keychain (Darwin only, best-effort)
#   3. Exit 1 with diagnostic message
set -euo pipefail

# 1. Environment variable
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "$ANTHROPIC_API_KEY"
  exit 0
fi

# 2. macOS Keychain fallback
if [[ "$(uname)" == "Darwin" ]]; then
  key=$(security find-generic-password -s "claude-api-key" -w 2>/dev/null || true)
  if [[ -n "$key" ]]; then
    echo "$key"
    exit 0
  fi
fi

# 3. Failure
echo "Error: ANTHROPIC_API_KEY is not set and could not be resolved." >&2
echo "Set it via: export ANTHROPIC_API_KEY=<your-key>" >&2
exit 1
