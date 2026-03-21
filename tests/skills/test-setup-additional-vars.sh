#!/usr/bin/env bash
# test-setup-additional-vars.sh — Verify /setup SKILL.md contains the additional variable configuration step
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

SKILL_FILE="${SCRIPT_DIR}/../../skills/setup/SKILL.md"

echo "=== test-setup-additional-vars ==="

# --- Test: SKILL.md contains the additional variable configuration step ---
CONTENT="$(cat "$SKILL_FILE")"

assert_match "SKILL.md contains Step 2 for additional variable configuration" \
  "Step 2.*[Aa]dditional" "$CONTENT"

assert_match "SKILL.md references envs/README.md for variable catalog" \
  "envs/README.md" "$CONTENT"

assert_match "SKILL.md mentions AskUserQuestion for additional vars prompt" \
  "AskUserQuestion" "$CONTENT"

# --- Test: separator parsing examples are documented ---
assert_match "SKILL.md documents = separator" \
  "CEKERNEL_.*=.*[0-9]" "$CONTENT"

assert_match "SKILL.md documents : separator" \
  "CEKERNEL_.*:.*[0-9]" "$CONTENT"

assert_match "SKILL.md documents space separator" \
  "CEKERNEL_.* [0-9]" "$CONTENT"

# --- Test: validation against envs/README.md is specified ---
assert_match "SKILL.md specifies validation of variable names against catalog" \
  "[Vv]alid" "$CONTENT"

# --- Test: step numbering is consistent (no duplicate step numbers) ---
# After insertion, steps should be 1, 2, 3, 4, 5
assert_match "SKILL.md has Step 1" "### Step 1:" "$CONTENT"
assert_match "SKILL.md has Step 2" "### Step 2:" "$CONTENT"
assert_match "SKILL.md has Step 3" "### Step 3:" "$CONTENT"
assert_match "SKILL.md has Step 4" "### Step 4:" "$CONTENT"
assert_match "SKILL.md has Step 5" "### Step 5:" "$CONTENT"

# --- Test: loop for multiple variables is documented ---
assert_match "SKILL.md contains loop/repeat mechanism for multiple vars" \
  "([Rr]epeat|[Aa]nother|more)" "$CONTENT"

report_results
