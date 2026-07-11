#!/usr/bin/env bash
# wait-ci.sh — Foreground blocking CI wait primitive for Workers
#
# Usage: wait-ci.sh <pr-number>
#
# Runs `gh pr checks <pr> --watch` in the foreground with chunk timeout
# control to avoid the Bash tool's 600s hard limit (#650). Follows the
# same chunk pattern as watch.sh (#630).
#
# Environment:
#   CEKERNEL_CI_CHUNK_TIMEOUT — Max seconds per invocation before
#     returning a "watching" sentinel (default: 540). Must be shorter
#     than the Bash tool's 600s hard limit to avoid SIGTERM.
#     The Worker re-calls wait-ci.sh on a "watching" result.
#
# Output (JSON to stdout):
#   {"result":"passed","pr":<N>}     — All CI checks passed
#   {"result":"failed","pr":<N>}     — One or more CI checks failed
#   {"result":"watching","pr":<N>}   — Chunk timeout; re-invoke needed
#
# Exit codes:
#   0 — Always (caller inspects JSON result)
#   1 — Usage error (missing arguments)
set -euo pipefail

PR_NUMBER="${1:?Usage: wait-ci.sh <pr-number>}"
CHUNK_TIMEOUT="${CEKERNEL_CI_CHUNK_TIMEOUT:-540}"

# Run gh pr checks --watch in background so we can enforce chunk timeout
gh pr checks "$PR_NUMBER" --watch &
GH_PID=$!

# Wait for gh to finish, enforcing chunk timeout
ELAPSED=0
while kill -0 "$GH_PID" 2>/dev/null; do
  if [[ $ELAPSED -ge $CHUNK_TIMEOUT ]]; then
    # Chunk timeout reached — kill gh and return watching sentinel
    kill "$GH_PID" 2>/dev/null || true
    wait "$GH_PID" 2>/dev/null || true
    echo "{\"result\":\"watching\",\"pr\":${PR_NUMBER}}"
    exit 0
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

# gh finished — check its exit code
GH_EXIT=0
wait "$GH_PID" || GH_EXIT=$?

if [[ $GH_EXIT -eq 0 ]]; then
  echo "{\"result\":\"passed\",\"pr\":${PR_NUMBER}}"
else
  echo "{\"result\":\"failed\",\"pr\":${PR_NUMBER}}"
fi
