#!/usr/bin/env bash
# preflight.sh — Preflight checks for schedule registration
#
# Usage: source preflight.sh
#
# Functions:
#   schedule_preflight_check <type> <repo> — Validate environment for scheduling
#     type: "cron" or "at"
#     repo: path to the target repository
#     Returns 0 if all checks pass, 1 if any fail.
#     All checks run (no early exit) so user sees all failures at once.

schedule_preflight_check() {
  local type="${1:?Usage: schedule_preflight_check <cron|at> <repo>}"
  local repo="${2:?Usage: schedule_preflight_check <cron|at> <repo>}"

  # Resolve CEKERNEL_DIR for resolve-api-key.sh
  local cekernel_dir
  cekernel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  local failed=0

  # 1. API key is resolvable (env var or Keychain)
  if bash "${cekernel_dir}/scripts/scheduler/resolve-api-key.sh" >/dev/null 2>&1; then
    echo "  OK: API key is resolvable"
  else
    echo "  FAIL: API key cannot be resolved" >&2
    echo "    Set ANTHROPIC_API_KEY or add key to macOS Keychain" >&2
    failed=1
  fi

  # 2. Required commands: claude, gh, git
  for cmd in claude gh git; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  OK: ${cmd} found ($(command -v "$cmd"))"
    else
      echo "  FAIL: ${cmd} not found in PATH" >&2
      failed=1
    fi
  done

  # 3. .claude/settings.json exists
  if [[ -f "${repo}/.claude/settings.json" ]]; then
    echo "  OK: ${repo}/.claude/settings.json exists"
  else
    echo "  FAIL: ${repo}/.claude/settings.json not found" >&2
    echo "    Required for non-interactive tool permissions" >&2
    failed=1
  fi

  # 4. OS scheduler accessibility
  case "$(uname)" in
    Darwin)
      if command -v launchctl >/dev/null 2>&1; then
        echo "  OK: launchctl available"
      else
        echo "  FAIL: launchctl not found" >&2
        failed=1
      fi
      ;;
    Linux)
      if command -v crontab >/dev/null 2>&1; then
        echo "  OK: crontab available"
      else
        echo "  FAIL: crontab not found" >&2
        failed=1
      fi
      ;;
  esac

  # 5. For /at on Linux: check atd is running
  if [[ "$type" == "at" && "$(uname)" == "Linux" ]]; then
    if systemctl is-active atd >/dev/null 2>&1; then
      echo "  OK: atd is active"
    else
      echo "  FAIL: atd is not running" >&2
      echo "    Start it via: sudo systemctl start atd" >&2
      failed=1
    fi
  fi

  return "$failed"
}
