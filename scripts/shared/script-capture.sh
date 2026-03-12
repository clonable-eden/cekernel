#!/usr/bin/env bash
# script-capture.sh — Runner script generator for stdout/stderr capture
#
# Usage: source script-capture.sh
#
# Functions:
#   write_runner_script <issue> <worktree> <session_id> <agent_name> <prompt> <log_file>
#     Generates a runner script at ${CEKERNEL_IPC_DIR}/run-${issue}.sh
#     and writes the prompt to ${CEKERNEL_IPC_DIR}/prompt-${issue}.txt.
#     The runner handles macOS (BSD) vs Linux (GNU) `script` differences internally.
#     Prompt is passed via file — no shell escaping needed.
#     stdout: path to the generated runner script
#
#   ensure_log_dir
#     Creates ${CEKERNEL_IPC_DIR}/logs/ if it doesn't exist.

# write_runner_script <issue> <worktree> <session_id> <agent_name> <prompt> <log_file>
write_runner_script() {
  local issue="${1:?Usage: write_runner_script <issue> <worktree> <session_id> <agent_name> <prompt> <log_file>}"
  local worktree="${2:?}"
  local session_id="${3:?}"
  local agent_name="${4:?}"
  local prompt="${5:?}"
  local log_file="${6:?}"

  local runner="${CEKERNEL_IPC_DIR}/run-${issue}.sh"
  local prompt_file="${CEKERNEL_IPC_DIR}/prompt-${issue}.txt"

  # Write prompt to file — no escaping needed
  printf '%s' "$prompt" > "$prompt_file"

  # Generate runner script
  # Variables expanded at generation time: worktree, session_id, agent_name, prompt_file, log_file
  # Variables expanded at runtime: PROMPT (read from file), uname check
  cat > "$runner" <<RUNNER
#!/usr/bin/env bash
cd '${worktree}'
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN
export CEKERNEL_SESSION_ID='${session_id}'

PROMPT=\$(cat '${prompt_file}')
LOG_FILE='${log_file}'

if [[ "\$(uname -s)" == "Darwin" ]]; then
  # macOS (BSD): script -q <logfile> <command> [args...]
  # Arguments passed directly via execvp() — no shell interpretation
  exec script -q "\$LOG_FILE" claude -p --agent ${agent_name} "\$PROMPT"
else
  # Linux (GNU): script -c <command> uses sh -c internally
  # Export prompt as env var, use single quotes to prevent premature expansion
  export __CEKERNEL_PROMPT="\$PROMPT"
  exec script -q -c 'claude -p --agent ${agent_name} "\$__CEKERNEL_PROMPT"' "\$LOG_FILE"
fi
RUNNER
  chmod +x "$runner"

  echo "$runner"
}

# ensure_log_dir
# Creates the log directory under CEKERNEL_IPC_DIR.
ensure_log_dir() {
  mkdir -p "${CEKERNEL_IPC_DIR}/logs"
}
