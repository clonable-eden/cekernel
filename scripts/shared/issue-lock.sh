#!/usr/bin/env bash
# issue-lock.sh — Repo × issue granularity lockfile for duplicate Worker prevention
#
# Usage: source issue-lock.sh
#
# Functions:
#   issue_lock_acquire <repo-path> <issue-number>  — Acquire lock (mkdir-based, PID written, stale detection)
#   issue_lock_release <repo-path> <issue-number>  — Release lock
#   issue_lock_check <repo-path> <issue-number>    — Check lock state (0=locked, 1=unlocked)
#   issue_lock_update_pid <repo-path> <issue-number> <new-pid> — Update PID in existing lock
#   issue_lock_repo_hash <repo-path>               — Return short hash for repo path
#
# Lock path: ${CEKERNEL_VAR_DIR}/locks/<repo-hash>/<issue-number>.lock/
#
# Environment variables (overridable for testing):
#   CEKERNEL_VAR_DIR — Base directory (default: /usr/local/var/cekernel)

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}"

issue_lock_repo_hash() {
  local repo_path="${1:?Usage: issue_lock_repo_hash <repo-path>}"
  if command -v sha256sum >/dev/null 2>&1; then
    echo -n "$repo_path" | sha256sum | cut -c1-12
  else
    echo -n "$repo_path" | shasum -a 256 | cut -c1-12
  fi
}

issue_lock_acquire() {
  local repo_path="${1:?Usage: issue_lock_acquire <repo-path> <issue-number>}"
  local issue_number="${2:?Usage: issue_lock_acquire <repo-path> <issue-number>}"

  local hash
  hash=$(issue_lock_repo_hash "$repo_path")
  local lock_dir="${CEKERNEL_VAR_DIR}/locks/${hash}/${issue_number}.lock"

  mkdir -p "${CEKERNEL_VAR_DIR}/locks/${hash}"

  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" > "${lock_dir}/pid"
    return 0
  fi

  # Lock exists — check for stale lock
  local pid_file="${lock_dir}/pid"
  if [[ -f "$pid_file" ]]; then
    local holder_pid
    holder_pid=$(cat "$pid_file")
    if ! kill -0 "$holder_pid" 2>/dev/null; then
      # Holder is dead — remove stale lock and retry
      rm -f "$pid_file"
      rmdir "$lock_dir" 2>/dev/null || true
      if mkdir "$lock_dir" 2>/dev/null; then
        echo "$$" > "${lock_dir}/pid"
        return 0
      fi
    fi
  fi

  echo "Error: issue #${issue_number} is already locked (repo: ${repo_path})" >&2
  return 1
}

issue_lock_release() {
  local repo_path="${1:?Usage: issue_lock_release <repo-path> <issue-number>}"
  local issue_number="${2:?Usage: issue_lock_release <repo-path> <issue-number>}"

  local hash
  hash=$(issue_lock_repo_hash "$repo_path")
  local lock_dir="${CEKERNEL_VAR_DIR}/locks/${hash}/${issue_number}.lock"

  rm -f "${lock_dir}/pid"
  rmdir "$lock_dir" 2>/dev/null || true
}

issue_lock_update_pid() {
  local repo_path="${1:?Usage: issue_lock_update_pid <repo-path> <issue-number> <new-pid>}"
  local issue_number="${2:?Usage: issue_lock_update_pid <repo-path> <issue-number> <new-pid>}"
  local new_pid="${3:?Usage: issue_lock_update_pid <repo-path> <issue-number> <new-pid>}"

  local hash
  hash=$(issue_lock_repo_hash "$repo_path")
  local lock_dir="${CEKERNEL_VAR_DIR}/locks/${hash}/${issue_number}.lock"

  if [[ ! -d "$lock_dir" ]]; then
    echo "Error: no lock exists for issue #${issue_number} (repo: ${repo_path})" >&2
    return 1
  fi

  echo "$new_pid" > "${lock_dir}/pid"
}

issue_lock_check() {
  local repo_path="${1:?Usage: issue_lock_check <repo-path> <issue-number>}"
  local issue_number="${2:?Usage: issue_lock_check <repo-path> <issue-number>}"

  local hash
  hash=$(issue_lock_repo_hash "$repo_path")
  local lock_dir="${CEKERNEL_VAR_DIR}/locks/${hash}/${issue_number}.lock"

  if [[ -d "$lock_dir" ]]; then
    # Verify holder is still alive
    local pid_file="${lock_dir}/pid"
    if [[ -f "$pid_file" ]]; then
      local holder_pid
      holder_pid=$(cat "$pid_file")
      if kill -0 "$holder_pid" 2>/dev/null; then
        return 0  # locked
      fi
      # Holder is dead — stale lock
      return 1
    fi
    # Lock dir exists but no PID file — treat as stale
    return 1
  fi

  return 1  # unlocked
}
