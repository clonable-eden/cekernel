#!/usr/bin/env bash
# test-plugin-root-fallback.sh — CLAUDE_PLUGIN_ROOT fallback tests
#
# Verifies that when spawn-worker.sh is run directly,
# CLAUDE_PLUGIN_ROOT is auto-derived from SCRIPT_DIR/../..
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${CEKERNEL_DIR}/scripts/orchestrator"

echo "test: plugin-root-fallback"

# ── Test 1: Fallback works when CLAUDE_PLUGIN_ROOT is not set ──
# Unset CLAUDE_PLUGIN_ROOT in a subshell and verify the header logic from spawn-worker.sh
RESULT=$(
  unset CLAUDE_PLUGIN_ROOT
  # Reproduce spawn-worker.sh header: SCRIPT_DIR → CLAUDE_PLUGIN_ROOT fallback
  SCRIPT_DIR_LOCAL="$SCRIPTS_DIR"
  # Extract and execute the relevant logic from spawn-worker.sh
  bash -c "
    set -euo pipefail
    SCRIPT_DIR='${SCRIPTS_DIR}'
    source \"\${SCRIPT_DIR}/../shared/session-id.sh\"
    # This line should exist in spawn-worker.sh
    CLAUDE_PLUGIN_ROOT=\"\${CLAUDE_PLUGIN_ROOT:-\$(cd \"\${SCRIPT_DIR}/../..\" && pwd)}\"
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  "
)
assert_eq "Fallback derives CLAUDE_PLUGIN_ROOT from SCRIPT_DIR/../.." "$CEKERNEL_DIR" "$RESULT"

# ── Test 2: Existing CLAUDE_PLUGIN_ROOT is not overwritten ──
RESULT=$(
  export CLAUDE_PLUGIN_ROOT="/custom/plugin/root"
  bash -c "
    set -euo pipefail
    SCRIPT_DIR='${SCRIPTS_DIR}'
    source \"\${SCRIPT_DIR}/../shared/session-id.sh\"
    CLAUDE_PLUGIN_ROOT=\"\${CLAUDE_PLUGIN_ROOT:-\$(cd \"\${SCRIPT_DIR}/../..\" && pwd)}\"
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  "
)
assert_eq "Existing CLAUDE_PLUGIN_ROOT is preserved" "/custom/plugin/root" "$RESULT"

# ── Test 3: spawn-worker.sh source contains CLAUDE_PLUGIN_ROOT fallback line ──
# Verify the actual source file contains the fallback line
SPAWN_SCRIPT="${SCRIPTS_DIR}/spawn-worker.sh"
if grep -q 'CLAUDE_PLUGIN_ROOT=.*CLAUDE_PLUGIN_ROOT:-' "$SPAWN_SCRIPT"; then
  FOUND="yes"
else
  FOUND="no"
fi
assert_eq "spawn-worker.sh contains CLAUDE_PLUGIN_ROOT fallback" "yes" "$FOUND"

report_results
