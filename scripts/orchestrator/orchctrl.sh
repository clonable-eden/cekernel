#!/usr/bin/env bash
# orchctrl.sh — Worker control interface (systemctl for cekernel)
#
# Usage: orchctrl.sh <command> [args...]
#
# Commands:
#   ls                          List all workers across all sessions
#   inspect <target>            Detailed worker view
#   suspend <target>            Suspend a worker (send SUSPEND signal)
#   resume <target>             Resume a suspended worker
#   term <target>               Send TERM signal (graceful shutdown)
#   kill <target>               Force kill worker
#   nice <target> <priority>    Change worker priority
#   gc [--dry-run]              Clean up stale IPC/lock resources
#
# Target formats:
#   <issue>                     Match by issue number (unique across all sessions)
#   <repo>:<issue>              Filter by repo name prefix
#   <issue> --session <id>      Explicit session ID
#
# Exit codes:
#   0 — Success
#   1 — Error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/worker-priority.sh"
source "${SCRIPT_DIR}/../shared/checkpoint-file.sh"

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}"
IPC_BASE="${CEKERNEL_IPC_BASE:-${CEKERNEL_VAR_DIR}/ipc}"

# ── Usage ──
usage() {
  cat >&2 <<'USAGE'
Usage: orchctrl.sh <command> [args...]

Commands:
  ls                          List all workers
  inspect <target>            Detailed worker view
  suspend <target>            Suspend a worker
  resume <target>             Resume a suspended worker
  term <target>               Send TERM signal
  kill <target>               Force kill worker
  nice <target> <priority>    Change priority
  gc [--dry-run]              Clean up stale resources

Target: <issue> | <repo>:<issue> | <issue> --session <id>
USAGE
  return 1
}

# ── Target resolution ──
# Scans all sessions in IPC_BASE to find a unique worker matching the target.
# Sets: RESOLVED_SESSION, RESOLVED_ISSUE
RESOLVED_SESSION=""
RESOLVED_ISSUE=""

resolve_target() {
  local target="" session_filter=""

  # Parse target and --session flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) session_filter="${2:?--session requires a value}"; shift 2 ;;
      *) target="$1"; shift ;;
    esac
  done

  [[ -n "$target" ]] || { echo "Error: target required" >&2; return 1; }

  local issue repo_prefix
  if [[ "$target" == *:* ]]; then
    repo_prefix="${target%%:*}"
    issue="${target#*:}"
  else
    repo_prefix=""
    issue="$target"
  fi

  # If --session given, use it directly
  if [[ -n "$session_filter" ]]; then
    local ipc_dir="${IPC_BASE}/${session_filter}"
    if [[ -p "${ipc_dir}/worker-${issue}" ]]; then
      RESOLVED_SESSION="$session_filter"
      RESOLVED_ISSUE="$issue"
      return 0
    else
      echo "Error: worker #${issue} not found in session ${session_filter}" >&2
      return 1
    fi
  fi

  # Scan all sessions for matching workers
  local matches=()
  if [[ -d "$IPC_BASE" ]]; then
    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue
      local sid
      sid=$(basename "$session_dir")

      # Apply repo filter: match repo name from metadata file or session ID prefix
      if [[ -n "$repo_prefix" ]]; then
        local sid_repo
        if [[ -f "${session_dir}repo" ]]; then
          sid_repo=$(tr -d '[:space:]' < "${session_dir}repo")
        else
          sid_repo="${sid%-*}"
        fi
        [[ "$sid_repo" == "$repo_prefix" ]] || continue
      fi

      if [[ -p "${session_dir}worker-${issue}" ]]; then
        matches+=("${sid}:${issue}")
      fi
    done
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "Error: no worker found for target '${target}'" >&2
    return 1
  elif [[ ${#matches[@]} -gt 1 ]]; then
    echo "Error: ambiguous target '${target}'. Candidates:" >&2
    for m in "${matches[@]}"; do
      echo "  - ${m}" >&2
    done
    return 1
  fi

  RESOLVED_SESSION="${matches[0]%%:*}"
  RESOLVED_ISSUE="${matches[0]#*:}"
  return 0
}

# ── Helper: set IPC context for resolved target ──
set_ipc_context() {
  export CEKERNEL_SESSION_ID="$RESOLVED_SESSION"
  export CEKERNEL_IPC_DIR="${IPC_BASE}/${RESOLVED_SESSION}"
}

# ── Helper: compute elapsed time from FIFO ──
compute_elapsed() {
  local fifo="$1"
  local created=""

  if stat -f '%m' "$fifo" &>/dev/null; then
    created=$(stat -f '%m' "$fifo")
  elif stat -c '%Y' "$fifo" &>/dev/null; then
    created=$(stat -c '%Y' "$fifo")
  fi

  if [[ -n "$created" ]]; then
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - created))
    if [[ $elapsed -ge 3600 ]]; then
      echo "$((elapsed / 3600))h$((elapsed % 3600 / 60))m"
    elif [[ $elapsed -ge 60 ]]; then
      echo "$((elapsed / 60))m"
    else
      echo "${elapsed}s"
    fi
  fi
}

# ── Helper: detect backend from metadata file (with heuristic fallback) ──
detect_backend() {
  local ipc_dir="$1" issue="$2"

  # Primary: read from metadata file written at spawn time
  local backend_file="${ipc_dir}/worker-${issue}.backend"
  if [[ -f "$backend_file" ]]; then
    tr -d '[:space:]' < "$backend_file"
    return
  fi

  # Fallback: heuristic detection from handle file (pre-#311 workers)
  local handle_file=""
  for hf in "${ipc_dir}"/handle-"${issue}".*; do
    [[ -f "$hf" ]] && handle_file="$hf" && break
  done

  if [[ -z "$handle_file" ]]; then
    echo "unknown"
    return
  fi

  local handle_content
  handle_content=$(tr -d '[:space:]' < "$handle_file")

  if [[ "$handle_content" == *:*.* ]]; then
    echo "tmux"
  elif [[ -f "${ipc_dir}/logs/worker-${issue}.stdout.log" ]]; then
    echo "headless"
  else
    echo "wezterm"
  fi
}

# ══════════════════════════════════════════════
# Commands
# ══════════════════════════════════════════════

# ── ls: List all workers across all sessions ──
cmd_ls() {
  local found=0

  if [[ ! -d "$IPC_BASE" ]]; then
    echo "no workers."
    return 0
  fi

  for session_dir in "$IPC_BASE"/*/; do
    [[ -d "$session_dir" ]] || continue
    local sid
    sid=$(basename "$session_dir")
    local sid_repo
    if [[ -f "${session_dir}repo" ]]; then
      sid_repo=$(tr -d '[:space:]' < "${session_dir}repo")
    else
      sid_repo="${sid%-*}"
    fi

    for fifo in "$session_dir"worker-*; do
      [[ -p "$fifo" ]] || continue
      local issue
      issue=$(basename "$fifo" | sed 's/^worker-//')
      found=$((found + 1))

      # Set context for shared helpers
      export CEKERNEL_IPC_DIR="$session_dir"

      # Type
      local process_type="unknown"
      local type_file="${session_dir}worker-${issue}.type"
      if [[ -f "$type_file" ]]; then
        process_type=$(tr -d '[:space:]' < "$type_file")
      fi

      # State
      local state_json state detail
      state_json=$(worker_state_read "$issue")
      state=$(echo "$state_json" | jq -r '.state')
      detail=$(echo "$state_json" | jq -r '.detail')

      # Priority
      local priority_json priority priority_name
      priority_json=$(worker_priority_read "$issue")
      priority=$(echo "$priority_json" | jq -r '.priority')
      priority_name=$(echo "$priority_json" | jq -r '.priority_name')

      # Elapsed time
      local elapsed
      elapsed=$(compute_elapsed "$fifo")

      # Backend
      local backend
      backend=$(detect_backend "$session_dir" "$issue")

      jq -cn \
        --arg session "$sid" \
        --arg repo "$sid_repo" \
        --argjson issue "$issue" \
        --arg type "$process_type" \
        --arg state "$state" \
        --arg detail "$detail" \
        --argjson priority "$priority" \
        --arg priority_name "$priority_name" \
        --arg elapsed "${elapsed:-}" \
        --arg backend "$backend" \
        '{session: $session, repo: $repo, issue: $issue, type: $type, state: $state, detail: $detail, priority: $priority, priority_name: $priority_name, elapsed: $elapsed, backend: $backend}'
    done
  done

  if [[ "$found" -eq 0 ]]; then
    echo "no workers."
  fi
}

# ── inspect: Detailed worker view ──
cmd_inspect() {
  resolve_target "$@" || return 1
  set_ipc_context

  local fifo="${CEKERNEL_IPC_DIR}/worker-${RESOLVED_ISSUE}"

  # Type
  local process_type="unknown"
  local type_file="${CEKERNEL_IPC_DIR}/worker-${RESOLVED_ISSUE}.type"
  if [[ -f "$type_file" ]]; then
    process_type=$(tr -d '[:space:]' < "$type_file")
  fi

  # State
  local state_json
  state_json=$(worker_state_read "$RESOLVED_ISSUE")
  local state
  state=$(echo "$state_json" | jq -r '.state')
  local detail
  detail=$(echo "$state_json" | jq -r '.detail')
  local timestamp
  timestamp=$(echo "$state_json" | jq -r '.timestamp')

  # Priority
  local priority_json
  priority_json=$(worker_priority_read "$RESOLVED_ISSUE")
  local priority
  priority=$(echo "$priority_json" | jq -r '.priority')

  # Elapsed time
  local elapsed=""
  if [[ -p "$fifo" ]]; then
    elapsed=$(compute_elapsed "$fifo")
  fi

  # Backend
  local backend
  backend=$(detect_backend "$CEKERNEL_IPC_DIR" "$RESOLVED_ISSUE")

  # Worktree (try to find from git worktree list)
  local worktree=""
  worktree=$(git worktree list --porcelain 2>/dev/null \
    | grep "^worktree " \
    | sed 's/^worktree //' \
    | grep "/issue/${RESOLVED_ISSUE}-" \
    | head -1 || true)

  # Checkpoint
  local checkpoint_json='{"exists":false}'
  if [[ -n "$worktree" ]]; then
    checkpoint_json=$(read_checkpoint_file "$worktree")
  fi

  jq -cn \
    --arg session "$RESOLVED_SESSION" \
    --argjson issue "$RESOLVED_ISSUE" \
    --arg type "$process_type" \
    --arg state "$state" \
    --arg detail "$detail" \
    --arg timestamp "$timestamp" \
    --argjson priority "$priority" \
    --arg elapsed "${elapsed:-}" \
    --arg backend "$backend" \
    --arg worktree "${worktree:-}" \
    --argjson checkpoint "$checkpoint_json" \
    '{session: $session, issue: $issue, type: $type, state: $state, detail: $detail, timestamp: $timestamp, priority: $priority, elapsed: $elapsed, backend: $backend, worktree: $worktree, checkpoint: $checkpoint}'
}

# ── suspend: Send SUSPEND signal ──
cmd_suspend() {
  resolve_target "$@" || return 1
  set_ipc_context

  # Check current state
  local state_json state
  state_json=$(worker_state_read "$RESOLVED_ISSUE")
  state=$(echo "$state_json" | jq -r '.state')

  case "$state" in
    RUNNING|WAITING|READY)
      echo "SUSPEND" > "${CEKERNEL_IPC_DIR}/worker-${RESOLVED_ISSUE}.signal"
      echo "Signal SUSPEND sent to worker #${RESOLVED_ISSUE}" >&2
      ;;
    *)
      echo "Error: cannot suspend worker #${RESOLVED_ISSUE} in state ${state}" >&2
      return 1
      ;;
  esac
}

# ── resume: Resume a SUSPENDED worker ──
cmd_resume() {
  resolve_target "$@" || return 1
  set_ipc_context

  # Check current state
  local state_json state
  state_json=$(worker_state_read "$RESOLVED_ISSUE")
  state=$(echo "$state_json" | jq -r '.state')

  if [[ "$state" != "SUSPENDED" ]]; then
    echo "Error: cannot resume worker #${RESOLVED_ISSUE} in state ${state} (must be SUSPENDED)" >&2
    return 1
  fi

  # Change state to READY
  worker_state_write "$RESOLVED_ISSUE" READY "resume-requested"
  echo "Worker #${RESOLVED_ISSUE} state changed to READY (session: ${RESOLVED_SESSION})." >&2
  echo "Run: export CEKERNEL_SESSION_ID=${RESOLVED_SESSION} && spawn-worker.sh --resume ${RESOLVED_ISSUE}" >&2
}

# ── term: Send TERM signal (graceful shutdown) ──
cmd_term() {
  resolve_target "$@" || return 1
  set_ipc_context

  echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-${RESOLVED_ISSUE}.signal"
  echo "Signal TERM sent to worker #${RESOLVED_ISSUE}" >&2
}

# ── kill: Force kill worker ──
cmd_kill() {
  resolve_target "$@" || return 1
  set_ipc_context

  # Detect backend once for all handles
  local backend
  backend=$(detect_backend "$CEKERNEL_IPC_DIR" "$RESOLVED_ISSUE")

  # Kill all handle files for this issue (Worker + Reviewer)
  for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${RESOLVED_ISSUE}".*; do
    [[ -f "$handle_file" ]] || continue
    local handle_content
    handle_content=$(tr -d '[:space:]' < "$handle_file")

    case "$backend" in
      tmux)
        local window_target
        window_target=$(echo "$handle_content" | sed 's/\.[0-9]*$//')
        tmux kill-window -t "$window_target" 2>/dev/null || true
        ;;
      headless)
        kill -- -"$handle_content" 2>/dev/null || kill "$handle_content" 2>/dev/null || true
        ;;
      *)
        # wezterm or unknown — try wezterm pane kill
        wezterm cli kill-pane --pane-id "$handle_content" 2>/dev/null || true
        ;;
    esac
  done

  # Mark as terminated
  worker_state_write "$RESOLVED_ISSUE" TERMINATED "killed"
  echo "Worker #${RESOLVED_ISSUE} killed." >&2
}

# ── nice: Change worker priority ──
cmd_nice() {
  # Parse: all args except the last are target + flags, last is priority
  local all_args=("$@")

  if [[ ${#all_args[@]} -lt 2 ]]; then
    echo "Error: usage: orchctrl.sh nice <target> <priority>" >&2
    return 1
  fi

  # Separate --session and its value from positional args
  local positional=()
  local session_flag=""
  local i=0
  while [[ $i -lt ${#all_args[@]} ]]; do
    if [[ "${all_args[$i]}" == "--session" ]]; then
      session_flag="${all_args[$((i+1))]}"
      i=$((i + 2))
    else
      positional+=("${all_args[$i]}")
      i=$((i + 1))
    fi
  done

  if [[ ${#positional[@]} -lt 2 ]]; then
    echo "Error: usage: orchctrl.sh nice <target> <priority>" >&2
    return 1
  fi

  # Last positional arg is priority, first is target
  local last_idx=$((${#positional[@]} - 1))
  local priority="${positional[$last_idx]}"
  local target="${positional[0]}"

  # Rebuild resolve args
  local resolve_args=("$target")
  if [[ -n "$session_flag" ]]; then
    resolve_args+=(--session "$session_flag")
  fi

  resolve_target "${resolve_args[@]}" || return 1
  set_ipc_context

  worker_priority_write "$RESOLVED_ISSUE" "$priority" || return 1

  local updated_json
  updated_json=$(worker_priority_read "$RESOLVED_ISSUE")
  echo "Worker #${RESOLVED_ISSUE} priority updated." >&2
  echo "$updated_json"
}

# ── gc: Clean up stale IPC/lock resources ──
cmd_gc() {
  local dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) echo "Error: unknown option '$1'" >&2; return 1 ;;
    esac
  done

  local cleaned=0
  local locks_dir="${CEKERNEL_VAR_DIR}/locks"

  # Stale timeout for NEW/READY state (seconds). Default: 30 minutes.
  local stale_timeout="${CEKERNEL_GC_STALE_TIMEOUT:-1800}"

  # ── Helper: check if a FIFO is stale ──
  # Returns 0 (stale) or 1 (active).
  # A FIFO is stale when:
  #   - State is TERMINATED and no live handle exists
  #   - No handle exists and state is NEW/READY past stale_timeout
  #   - Handle exists but the referenced process is dead
  _gc_is_stale_fifo() {
    local sdir="$1" issue="$2" fifo="$3" timeout="$4"

    # Check for any handle file
    local has_live_handle=0
    local has_any_handle=0
    for hf in "${sdir}"handle-"${issue}".*; do
      [[ -f "$hf" ]] || continue
      has_any_handle=1
      local handle_content
      handle_content=$(tr -d '[:space:]' < "$hf")
      # For headless backend, handle is a PID
      # For tmux, handle is session:window.pane — check if tmux session exists
      # For wezterm, handle is a pane ID
      # Simple heuristic: if handle is numeric, check kill -0; otherwise assume stale
      if [[ "$handle_content" =~ ^[0-9]+$ ]]; then
        if kill -0 "$handle_content" 2>/dev/null; then
          has_live_handle=1
          break
        fi
      elif [[ "$handle_content" == *:*.* ]]; then
        # tmux pane target — check if tmux session exists
        if tmux has-session -t "${handle_content%%:*}" 2>/dev/null; then
          has_live_handle=1
          break
        fi
      else
        # Unknown handle format — assume alive to be safe
        has_live_handle=1
        break
      fi
    done

    # If there's a live handle, the FIFO is active
    if [[ "$has_live_handle" -eq 1 ]]; then
      return 1
    fi

    # Read state from state file
    local state="UNKNOWN"
    local state_file="${sdir}worker-${issue}.state"
    if [[ -f "$state_file" ]]; then
      local line
      line=$(cat "$state_file")
      state="${line%%:*}"
    fi

    # TERMINATED → always stale (process completed, FIFO should have been cleaned)
    if [[ "$state" == "TERMINATED" ]]; then
      return 0
    fi

    # Handle exists but process is dead → stale
    if [[ "$has_any_handle" -eq 1 ]]; then
      return 0
    fi

    # No handle, state is NEW/READY → check timeout
    if [[ "$state" == "NEW" || "$state" == "READY" ]]; then
      local created=""
      if stat -f '%m' "$fifo" &>/dev/null; then
        created=$(stat -f '%m' "$fifo")
      elif stat -c '%Y' "$fifo" &>/dev/null; then
        created=$(stat -c '%Y' "$fifo")
      fi
      if [[ -n "$created" ]]; then
        local now elapsed
        now=$(date +%s)
        elapsed=$((now - created))
        if [[ "$elapsed" -ge "$timeout" ]]; then
          return 0
        fi
      fi
      # Within timeout — still active
      return 1
    fi

    # No handle, non-terminal state (RUNNING/WAITING/SUSPENDED/UNKNOWN) → stale
    # (A RUNNING worker without any handle is abnormal)
    return 0
  }

  # ── 1. Collect active issues (FIFOs across all sessions) ──
  # Build a set of active issue numbers per session for orphan detection.
  # FIFOs are checked for staleness: if the process is dead or state is
  # TERMINATED, the FIFO is removed and not added to active_issues.
  # Uses a temp file instead of declare -A for bash 3.2 compatibility.
  local active_issues_file
  active_issues_file=$(mktemp /tmp/cekernel-gc-active.XXXXXX)

  if [[ -d "$IPC_BASE" ]]; then
    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue
      for fifo in "$session_dir"worker-*; do
        [[ -p "$fifo" ]] || continue
        local fname
        fname=$(basename "$fifo")
        # Only match worker-{issue} FIFOs (not worker-{issue}.state etc)
        [[ "$fname" == worker-* && "$fname" != *.* ]] || continue
        local issue="${fname#worker-}"

        # Check if this FIFO is stale
        if _gc_is_stale_fifo "$session_dir" "$issue" "$fifo" "$stale_timeout"; then
          # Stale: remove FIFO and do NOT add to active_issues
          if [[ "$dry_run" -eq 1 ]]; then
            echo "[dry-run] would remove stale FIFO: $fifo" >&2
          else
            rm -f "$fifo"
          fi
          cleaned=$((cleaned + 1))
        else
          echo "${session_dir}:${issue}" >> "$active_issues_file"
        fi
      done
    done
  fi

  # ── 2. Clean stale locks ──
  if [[ -d "$locks_dir" ]]; then
    for repo_hash_dir in "$locks_dir"/*/; do
      [[ -d "$repo_hash_dir" ]] || continue
      for lock_dir in "$repo_hash_dir"*.lock; do
        [[ -d "$lock_dir" ]] || continue
        local pid_file="${lock_dir}/pid"
        local is_stale=0

        if [[ -f "$pid_file" ]]; then
          local holder_pid
          holder_pid=$(cat "$pid_file")
          if ! kill -0 "$holder_pid" 2>/dev/null; then
            is_stale=1
          fi
        else
          # No PID file — treat as stale
          is_stale=1
        fi

        if [[ "$is_stale" -eq 1 ]]; then
          if [[ "$dry_run" -eq 1 ]]; then
            echo "[dry-run] would remove stale lock: $lock_dir" >&2
          else
            rm -f "${lock_dir}/pid"
            rmdir "$lock_dir" 2>/dev/null || true
          fi
          cleaned=$((cleaned + 1))
        fi
      done

      # Remove empty repo-hash directory
      if [[ "$dry_run" -eq 0 ]]; then
        rmdir "$repo_hash_dir" 2>/dev/null || true
      else
        # Check if it would be empty after lock removal
        local remaining
        remaining=$(find "$repo_hash_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [[ "$remaining" -eq 0 ]]; then
          echo "[dry-run] would remove empty repo-hash dir: $repo_hash_dir" >&2
        fi
      fi
    done
  fi

  # ── Helper: clean orphan files matching a glob pattern ──
  # Extracts issue number from filename using the given prefix, then checks
  # if a FIFO exists for that issue. If not, removes the file.
  # Args: session_dir glob_pattern prefix label
  _gc_clean_orphan_files() {
    local sdir="$1" pattern="$2" prefix="$3" label="$4"
    for orphan_file in ${sdir}${pattern}; do
      [[ -f "$orphan_file" ]] || continue
      local fname
      fname=$(basename "$orphan_file")
      local issue_with_ext="${fname#"${prefix}"}"
      local issue="${issue_with_ext%%.*}"

      # Skip if there's an active FIFO
      if grep -qxF "${sdir}:${issue}" "$active_issues_file" 2>/dev/null; then
        continue
      fi

      if [[ "$dry_run" -eq 1 ]]; then
        echo "[dry-run] would remove orphan ${label}: $orphan_file" >&2
      else
        rm -f "$orphan_file"
      fi
      cleaned=$((cleaned + 1))
    done
  }

  # ── 3. Clean orphan IPC files (no active FIFO) ──
  if [[ -d "$IPC_BASE" ]]; then
    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue

      _gc_clean_orphan_files "$session_dir" "worker-*.*"   "worker-"  "IPC file"
      _gc_clean_orphan_files "$session_dir" "handle-*.*"   "handle-"  "handle"
      _gc_clean_orphan_files "$session_dir" "payload-*.b64" "payload-" "payload"

      # Log files live in a subdirectory
      if [[ -d "${session_dir}logs" ]]; then
        _gc_clean_orphan_files "${session_dir}logs/" "worker-*" "worker-" "log"

        if [[ "$dry_run" -eq 0 ]]; then
          rmdir "${session_dir}logs" 2>/dev/null || true
        fi
      fi

      # Remove empty session directory
      if [[ "$dry_run" -eq 0 ]]; then
        rmdir "$session_dir" 2>/dev/null || true
      fi
    done
  fi

  # ── Cleanup temp file ──
  rm -f "$active_issues_file"

  # ── 4. Summary ──
  if [[ "$cleaned" -eq 0 ]]; then
    echo "gc: nothing to clean." >&2
  else
    if [[ "$dry_run" -eq 1 ]]; then
      echo "gc: ${cleaned} stale resources found (dry-run, nothing cleaned)." >&2
    else
      echo "gc: ${cleaned} stale resources cleaned." >&2
    fi
  fi
}

# ══════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  ls)      cmd_ls "$@" ;;
  inspect) cmd_inspect "$@" ;;
  suspend) cmd_suspend "$@" ;;
  resume)  cmd_resume "$@" ;;
  term)    cmd_term "$@" ;;
  kill)    cmd_kill "$@" ;;
  nice)    cmd_nice "$@" ;;
  gc)      cmd_gc "$@" ;;
  *)       usage ;;
esac
