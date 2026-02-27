#!/usr/bin/env bash
# backends/headless.sh — Headless backend (ADR-0005)
#
# Implements 4 external API functions using background processes.
# No terminal multiplexer required — Workers run as background processes
# with stdout/stderr redirected to log files.
#
# Sourced by backend-adapter.sh when CEKERNEL_BACKEND=headless.
#
# Handle file: ${CEKERNEL_IPC_DIR}/handle-{issue} contains PID (numeric).
# Process group: setsid creates a new process group for clean termination.

# ── External API ──

backend_available() {
  # Headless is always available — no external dependency
  return 0
}

# backend_spawn_worker <issue> <worktree> <prompt>
# Spawns a Worker as a background process via setsid.
# Saves PID to handle file internally.
backend_spawn_worker() {
  local issue="$1"
  local worktree="$2"
  local prompt="$3"

  # Ensure log directory exists
  local log_dir="${CEKERNEL_IPC_DIR}/logs"
  mkdir -p "$log_dir"
  local log_file="${log_dir}/worker-${issue}.stdout.log"

  # Launch Worker as a background process.
  # Bash creates a new process group for background jobs automatically,
  # so kill -- -$PID can terminate the entire group.
  # SESSION_ID is propagated as a direct environment variable.
  # Unset Claude Code session markers to avoid nested-session detection.
  # Use -p (print mode) for non-TTY execution.
  # NOTE: -p may hang without TTY due to upstream bug (claude-code#9026).
  (
    cd "$worktree" && \
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT && \
    CEKERNEL_SESSION_ID="${CEKERNEL_SESSION_ID:-}" \
    exec claude -p --agent "${CEKERNEL_AGENT_WORKER:-worker}" "$prompt"
  ) > "$log_file" 2>&1 &
  local pid=$!

  # Save handle (PID)
  echo "$pid" > "${CEKERNEL_IPC_DIR}/handle-${issue}"
}

# backend_worker_alive <issue>
# exit 0 if alive, exit 1 if dead or no handle
backend_worker_alive() {
  local issue="$1"
  local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}"

  [[ -f "$handle_file" ]] || return 1

  local pid
  pid=$(cat "$handle_file")
  kill -0 "$pid" 2>/dev/null
}

# backend_kill_worker <issue>
# Kills the entire process group. No error if handle missing or process dead.
backend_kill_worker() {
  local issue="$1"
  local handle_file="${CEKERNEL_IPC_DIR}/handle-${issue}"

  [[ -f "$handle_file" ]] || return 0

  local pid
  pid=$(cat "$handle_file")

  # Kill the Worker process and its children.
  # First try to kill the process group (negative PID).
  # Fall back to killing just the PID if process group kill fails.
  kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
}
