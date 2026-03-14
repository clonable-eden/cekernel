#!/usr/bin/env bash
# backends/headless.sh — Headless backend (ADR-0005)
#
# Implements 5 external API functions using background processes.
# No terminal multiplexer required — Workers run as background processes
# with stdout/stderr discarded (analysis uses transcripts, not log files).
#
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=headless.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue}.{type} contains PID (numeric).
# Process group: setsid creates a new process group for clean termination.

# ── External API ──

backend_available() {
  # Headless is always available — no external dependency
  return 0
}

# backend_spawn_worker <issue> <type> <worktree> <prompt> <agent-name>
# Spawns a Worker as a background process via setsid.
# Saves PID to handle file internally.
backend_spawn_worker() {
  local issue="$1"
  local type="$2"
  local worktree="$3"
  local prompt="$4"
  local agent_name="$5"

  # Launch Worker as a background process.
  # Bash creates a new process group for background jobs automatically,
  # so kill -- -$PID can terminate the entire group.
  # SESSION_ID is propagated as a direct environment variable.
  # Unset Claude Code session markers to avoid nested-session detection.
  # Use -p (print mode) for non-TTY execution.
  # NOTE: -p may hang without TTY due to upstream bug (claude-code#9026).
  # stdout/stderr discarded — analysis uses transcripts (ADR-0005, #347).
  (
    cd "$worktree" && \
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN && \
    CEKERNEL_SESSION_ID="${CEKERNEL_SESSION_ID:-}" \
    exec claude -p --agent "$agent_name" "$prompt"
  ) >/dev/null 2>&1 &
  local pid=$!

  # Save handle (PID)
  echo "$pid" > "${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
}

# backend_get_pid <issue> [type]
# Returns the Worker process PID.
# For headless backend, the handle IS the PID.
backend_get_pid() {
  local issue="$1"
  local type="${2:-}"

  local handle_file
  if [[ -n "$type" ]]; then
    handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
  else
    # Find any handle file for this issue
    handle_file=$(ls "${CEKERNEL_IPC_DIR}"/handle-"${issue}".* 2>/dev/null | head -1)
  fi

  if [[ -z "$handle_file" || ! -f "$handle_file" ]]; then
    echo "Error: no handle file for issue #${issue}" >&2
    return 1
  fi

  cat "$handle_file"
}

# backend_worker_alive <issue> [type]
# exit 0 if alive, exit 1 if dead or no handle
# If type is omitted, checks any handle-{issue}.* file.
backend_worker_alive() {
  local issue="$1"
  local type="${2:-}"

  if [[ -n "$type" ]]; then
    local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
    [[ -f "$handle_file" ]] || return 1
    local pid
    pid=$(cat "$handle_file")
    kill -0 "$pid" 2>/dev/null
  else
    local found=0
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      found=1
      local pid
      pid=$(cat "$handle_file")
      if kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
    done
    [[ "$found" -eq 1 ]] || return 1
    return 1
  fi
}

# backend_kill_worker <issue> [type]
# Kills the entire process group. No error if handle missing or process dead.
# If type is omitted, kills all handle-{issue}.* handles.
backend_kill_worker() {
  local issue="$1"
  local type="${2:-}"

  if [[ -n "$type" ]]; then
    local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}.${type}"
    [[ -f "$handle_file" ]] || return 0
    local pid
    pid=$(cat "$handle_file")
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  else
    for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${issue}".*; do
      [[ -f "$handle_file" ]] || continue
      local pid
      pid=$(cat "$handle_file")
      kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    done
  fi
}
