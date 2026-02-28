#!/usr/bin/env bash
# orchctrl.sh — Worker control interface (systemctl for cekernel)
#
# Usage: orchctrl.sh <command> [args...]
#
# Commands:
#   ls                          List all workers across all sessions
#   log <target>                Tail worker log
#   inspect <target>            Detailed worker view
#   suspend <target>            Suspend a worker (send SUSPEND signal)
#   resume <target>             Resume a suspended worker
#   term <target>               Send TERM signal (graceful shutdown)
#   kill <target>               Force kill worker
#   nice <target> <priority>    Change worker priority
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
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/worker-priority.sh"
source "${SCRIPT_DIR}/../shared/checkpoint-file.sh"

IPC_BASE="${CEKERNEL_IPC_BASE:-/tmp/cekernel-ipc}"

# ── Usage ──
usage() {
  cat >&2 <<'USAGE'
Usage: orchctrl.sh <command> [args...]

Commands:
  ls                          List all workers
  log <target>                Tail worker log
  inspect <target>            Detailed worker view
  suspend <target>            Suspend a worker
  resume <target>             Resume a suspended worker
  term <target>               Send TERM signal
  kill <target>               Force kill worker
  nice <target> <priority>    Change priority

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

      # Apply repo filter: match repo prefix (session ID format: {repo}-{hex8})
      if [[ -n "$repo_prefix" ]]; then
        local sid_repo="${sid%-*}"
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

# ── Helper: detect backend from handle file ──
detect_backend() {
  local ipc_dir="$1" issue="$2"
  local handle_file="${ipc_dir}/handle-${issue}"

  if [[ ! -f "$handle_file" ]]; then
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

# ── Helper: find best log file ──
find_log_file() {
  local ipc_dir="$1" issue="$2"

  # Prefer stdout.log (headless backend output)
  if [[ -f "${ipc_dir}/logs/worker-${issue}.stdout.log" ]]; then
    echo "${ipc_dir}/logs/worker-${issue}.stdout.log"
  elif [[ -f "${ipc_dir}/logs/worker-${issue}.log" ]]; then
    echo "${ipc_dir}/logs/worker-${issue}.log"
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
    local sid_repo="${sid%-*}"

    for fifo in "$session_dir"worker-*; do
      [[ -p "$fifo" ]] || continue
      local issue
      issue=$(basename "$fifo" | sed 's/^worker-//')
      found=$((found + 1))

      # Set context for shared helpers
      export CEKERNEL_IPC_DIR="$session_dir"

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

      # Log path
      local log_path
      log_path=$(find_log_file "$session_dir" "$issue")

      jq -cn \
        --arg session "$sid" \
        --arg repo "$sid_repo" \
        --argjson issue "$issue" \
        --arg state "$state" \
        --arg detail "$detail" \
        --argjson priority "$priority" \
        --arg priority_name "$priority_name" \
        --arg elapsed "${elapsed:-}" \
        --arg backend "$backend" \
        --arg log "${log_path:-}" \
        '{session: $session, repo: $repo, issue: $issue, state: $state, detail: $detail, priority: $priority, priority_name: $priority_name, elapsed: $elapsed, backend: $backend, log: $log}'
    done
  done

  if [[ "$found" -eq 0 ]]; then
    echo "no workers."
  fi
}

# ── log: Tail worker log ──
cmd_log() {
  resolve_target "$@" || return 1
  set_ipc_context

  local log_file
  log_file=$(find_log_file "$CEKERNEL_IPC_DIR" "$RESOLVED_ISSUE")

  if [[ -z "$log_file" ]]; then
    echo "Error: no log file found for worker #${RESOLVED_ISSUE}" >&2
    return 1
  fi

  echo "=== Log: worker #${RESOLVED_ISSUE} (session: ${RESOLVED_SESSION}) ===" >&2
  echo "=== File: ${log_file} ===" >&2
  tail -100 "$log_file"
}

# ── inspect: Detailed worker view ──
cmd_inspect() {
  resolve_target "$@" || return 1
  set_ipc_context

  local fifo="${CEKERNEL_IPC_DIR}/worker-${RESOLVED_ISSUE}"

  # State
  local state_json
  state_json=$(worker_state_read "$RESOLVED_ISSUE")
  local state
  state=$(echo "$state_json" | jq -r '.state')

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

  # Log files
  local log_files="[]"
  local logs=()
  if [[ -f "${CEKERNEL_IPC_DIR}/logs/worker-${RESOLVED_ISSUE}.stdout.log" ]]; then
    logs+=("${CEKERNEL_IPC_DIR}/logs/worker-${RESOLVED_ISSUE}.stdout.log")
  fi
  if [[ -f "${CEKERNEL_IPC_DIR}/logs/worker-${RESOLVED_ISSUE}.log" ]]; then
    logs+=("${CEKERNEL_IPC_DIR}/logs/worker-${RESOLVED_ISSUE}.log")
  fi
  if [[ ${#logs[@]} -gt 0 ]]; then
    log_files=$(printf '%s\n' "${logs[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
  fi

  jq -cn \
    --arg session "$RESOLVED_SESSION" \
    --argjson issue "$RESOLVED_ISSUE" \
    --arg state "$state" \
    --argjson priority "$priority" \
    --arg elapsed "${elapsed:-}" \
    --arg backend "$backend" \
    --arg worktree "${worktree:-}" \
    --argjson checkpoint "$checkpoint_json" \
    --argjson logs "$log_files" \
    '{session: $session, issue: $issue, state: $state, priority: $priority, elapsed: $elapsed, backend: $backend, worktree: $worktree, checkpoint: $checkpoint, logs: $logs}'
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

  local handle_file="${CEKERNEL_IPC_DIR}/handle-${RESOLVED_ISSUE}"

  if [[ -f "$handle_file" ]]; then
    local handle_content
    handle_content=$(tr -d '[:space:]' < "$handle_file")

    if [[ "$handle_content" == *:*.* ]]; then
      # tmux pane target — kill the window
      local window_target
      window_target=$(echo "$handle_content" | sed 's/\.[0-9]*$//')
      tmux kill-window -t "$window_target" 2>/dev/null || true
    elif [[ -f "${CEKERNEL_IPC_DIR}/logs/worker-${RESOLVED_ISSUE}.stdout.log" ]]; then
      # headless — handle is PID, kill process group
      kill -- -"$handle_content" 2>/dev/null || kill "$handle_content" 2>/dev/null || true
    else
      # wezterm — handle is pane ID
      wezterm cli kill-pane --pane-id "$handle_content" 2>/dev/null || true
    fi
  fi

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

# ══════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  ls)      cmd_ls "$@" ;;
  log)     cmd_log "$@" ;;
  inspect) cmd_inspect "$@" ;;
  suspend) cmd_suspend "$@" ;;
  resume)  cmd_resume "$@" ;;
  term)    cmd_term "$@" ;;
  kill)    cmd_kill "$@" ;;
  nice)    cmd_nice "$@" ;;
  *)       usage ;;
esac
