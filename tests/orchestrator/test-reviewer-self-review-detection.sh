#!/usr/bin/env bash
# test-reviewer-self-review-detection.sh — Verify reviewer.md pre-detects self-review
#
# The reviewer agent must compare PR author with the current GitHub user
# BEFORE attempting to submit APPROVE/REQUEST_CHANGES, avoiding 422 errors.
# This is a content-based regression guard (no executable scripts changed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REVIEWER_MD="${CEKERNEL_DIR}/agents/reviewer.md"

echo "test: reviewer-self-review-detection"

CONTENT=$(cat "$REVIEWER_MD")

# ── Test 1: reviewer.md contains self-review pre-detection section ──
if echo "$CONTENT" | grep -qi 'self-review.*detect\|detect.*self-review\|pre-detect\|pre-check'; then
  echo "  PASS: reviewer.md contains self-review detection section"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: reviewer.md should contain self-review detection section"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: reviewer.md compares PR author with current GitHub user ──
# Must retrieve PR author (gh pr view ... author) and current user (gh api user)
if echo "$CONTENT" | grep -q 'PR_AUTHOR' && echo "$CONTENT" | grep -q 'GH_USER'; then
  echo "  PASS: reviewer.md compares PR_AUTHOR with GH_USER"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: reviewer.md should compare PR_AUTHOR with GH_USER"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 3: reviewer.md retrieves PR author via gh pr view ──
if echo "$CONTENT" | grep -q 'gh pr view.*author'; then
  echo "  PASS: reviewer.md retrieves PR author via gh pr view"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: reviewer.md should retrieve PR author via gh pr view"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 4: reviewer.md retrieves current GitHub user ──
if echo "$CONTENT" | grep -q 'gh api user'; then
  echo "  PASS: reviewer.md retrieves current GitHub user via gh api user"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: reviewer.md should retrieve current GitHub user via gh api user"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: reviewer.md uses COMMENT event for self-review ──
if echo "$CONTENT" | grep -q 'event=COMMENT'; then
  echo "  PASS: reviewer.md uses COMMENT event for self-review"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: reviewer.md should use COMMENT event for self-review"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 6: self-review detection happens BEFORE review submission attempt ──
# The comparison (PR_AUTHOR == GH_USER) must appear before gh api .../reviews
COMPARISON_LINE=$(echo "$CONTENT" | grep -n 'PR_AUTHOR.*==.*GH_USER\|GH_USER.*==.*PR_AUTHOR' | head -1 | cut -d: -f1 || true)
REVIEW_API_LINE=$(echo "$CONTENT" | grep -n '\-f event=APPROVE\|\-f event=REQUEST_CHANGES' | head -1 | cut -d: -f1 || true)
if [[ -n "$COMPARISON_LINE" && -n "$REVIEW_API_LINE" && "$COMPARISON_LINE" -lt "$REVIEW_API_LINE" ]]; then
  echo "  PASS: self-review comparison appears before review API call"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: self-review comparison should appear before review API call (comparison:${COMPARISON_LINE:-missing}, api:${REVIEW_API_LINE:-missing})"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 7: no try-catch fallback pattern (422 error handling eliminated) ──
# The old pattern "if ! gh api ... 2>/dev/null; then" should be removed
OLD_PATTERN_COUNT=$(echo "$CONTENT" | grep -c 'if ! gh api.*reviews' || true)
if [[ "$OLD_PATTERN_COUNT" -eq 0 ]]; then
  echo "  PASS: old try-catch fallback pattern removed"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: old try-catch fallback pattern (if ! gh api ... 2>/dev/null) should be removed"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

report_results
