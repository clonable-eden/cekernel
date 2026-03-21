#!/usr/bin/env bash
# test-max-orchestrators-env.sh — Tests for CEKERNEL_MAX_ORCHESTRATORS variable
# in env profiles and skill definitions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: max-orchestrators-env"

# ══════════════════════════════════════════════
# Env profiles contain CEKERNEL_MAX_ORCHESTRATORS
# ══════════════════════════════════════════════

# ── Test 1: default.env contains CEKERNEL_MAX_ORCHESTRATORS ──
if grep -q 'CEKERNEL_MAX_ORCHESTRATORS' "${CEKERNEL_DIR}/envs/default.env"; then
  echo "  PASS: default.env contains CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: default.env missing CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: headless.env contains CEKERNEL_MAX_ORCHESTRATORS ──
if grep -q 'CEKERNEL_MAX_ORCHESTRATORS' "${CEKERNEL_DIR}/envs/headless.env"; then
  echo "  PASS: headless.env contains CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: headless.env missing CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: wezterm.env contains CEKERNEL_MAX_ORCHESTRATORS ──
if grep -q 'CEKERNEL_MAX_ORCHESTRATORS' "${CEKERNEL_DIR}/envs/wezterm.env"; then
  echo "  PASS: wezterm.env contains CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: wezterm.env missing CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: tmux.env contains CEKERNEL_MAX_ORCHESTRATORS ──
if grep -q 'CEKERNEL_MAX_ORCHESTRATORS' "${CEKERNEL_DIR}/envs/tmux.env"; then
  echo "  PASS: tmux.env contains CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: tmux.env missing CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ══════════════════════════════════════════════
# envs/README.md documents the variable
# ══════════════════════════════════════════════

# ── Test 5: README.md documents CEKERNEL_MAX_ORCHESTRATORS ──
if grep -q 'CEKERNEL_MAX_ORCHESTRATORS' "${CEKERNEL_DIR}/envs/README.md"; then
  echo "  PASS: envs/README.md documents CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: envs/README.md missing CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ══════════════════════════════════════════════
# Skill files reference the concurrency guard
# ══════════════════════════════════════════════

# ── Test 6: dispatch SKILL.md references orchctl count ──
# The SKILL.md uses "$ORCHCTL" count (variable reference), so check for orchctl.sh and count separately
if grep -q 'orchctl.sh' "${CEKERNEL_DIR}/skills/dispatch/SKILL.md" && grep -q 'count' "${CEKERNEL_DIR}/skills/dispatch/SKILL.md"; then
  echo "  PASS: dispatch SKILL.md references orchctl count"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: dispatch SKILL.md missing orchctl count reference"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: orchestrate SKILL.md references orchctl count ──
if grep -q 'orchctl.sh' "${CEKERNEL_DIR}/skills/orchestrate/SKILL.md" && grep -q 'count' "${CEKERNEL_DIR}/skills/orchestrate/SKILL.md"; then
  echo "  PASS: orchestrate SKILL.md references orchctl count"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: orchestrate SKILL.md missing orchctl count reference"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 8: dispatch SKILL.md references CEKERNEL_MAX_ORCHESTRATORS ──
if grep -q 'CEKERNEL_MAX_ORCHESTRATORS' "${CEKERNEL_DIR}/skills/dispatch/SKILL.md"; then
  echo "  PASS: dispatch SKILL.md references CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: dispatch SKILL.md missing CEKERNEL_MAX_ORCHESTRATORS reference"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 9: orchestrate SKILL.md references CEKERNEL_MAX_ORCHESTRATORS ──
if grep -q 'CEKERNEL_MAX_ORCHESTRATORS' "${CEKERNEL_DIR}/skills/orchestrate/SKILL.md"; then
  echo "  PASS: orchestrate SKILL.md references CEKERNEL_MAX_ORCHESTRATORS"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: orchestrate SKILL.md missing CEKERNEL_MAX_ORCHESTRATORS reference"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 10: dispatch SKILL.md references desktop-notify for limit notification ──
if grep -q 'desktop.notify\|desktop_notify' "${CEKERNEL_DIR}/skills/dispatch/SKILL.md"; then
  echo "  PASS: dispatch SKILL.md references desktop_notify"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: dispatch SKILL.md missing desktop_notify reference"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

report_results
