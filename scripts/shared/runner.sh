#!/usr/bin/env bash
# runner.sh — Runner script generator for Worker processes
#
# Usage: source runner.sh
#
# Functions:
#   write_runner_script <issue> <worktree> <session_id> <agent_name> <prompt>
#     Generates a runner script at ${CEKERNEL_IPC_DIR}/run-${issue}.sh
#     and writes the prompt to ${CEKERNEL_IPC_DIR}/prompt-${issue}.txt.
#     Prompt is passed via file — no shell escaping needed.
#     stdout: path to the generated runner script

# ── Dependencies ──
_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "${_RUNNER_DIR}/bare-mode.sh"

# write_runner_script <issue> <worktree> <session_id> <agent_name> <prompt>
write_runner_script() {
  local issue="${1:?Usage: write_runner_script <issue> <worktree> <session_id> <agent_name> <prompt>}"
  local worktree="${2:?}"
  local session_id="${3:?}"
  local agent_name="${4:?}"
  local prompt="${5:?}"

  local runner="${CEKERNEL_IPC_DIR}/run-${issue}.sh"
  local prompt_file="${CEKERNEL_IPC_DIR}/prompt-${issue}.txt"

  # --bare requires an explicit auth path — fail before generating a runner
  # that would die on auth (Rule of Repair, ADR-0016 Phase 0).
  bare_mode_preflight || return 1
  local bare_flags
  bare_flags="$(bare_mode_flags "$worktree")"

  # Write prompt to file — no escaping needed
  printf '%s' "$prompt" > "$prompt_file"

  # Generate runner script
  # Variables expanded at generation time: worktree, session_id, agent_name,
  # prompt_file, bare_flags (--bare + explicit context, ADR-0016 Phase 0)
  # Variables expanded at runtime: PROMPT (read from file)
  cat > "$runner" <<RUNNER
#!/usr/bin/env bash
cd '${worktree}'
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ACCESS_TOKEN
source .cekernel-env

PROMPT=\$(cat '${prompt_file}')

exec claude -p ${bare_flags} --agent ${agent_name} "\$PROMPT"
RUNNER
  chmod +x "$runner"

  echo "$runner"
}
