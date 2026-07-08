#!/usr/bin/env bats
# spawn.bats — bats-core tests for scripts/orchestrator/spawn.sh
#
# Runs spawn.sh end-to-end with mocked gh/claude in a temp clone
# (headless backend) and asserts the recorded claude argv (ADR-0017) —
# never the text of generated scripts. The claude shim is the canonical
# mock-claude helper emulating the --bg delegated-spawn contract
# (ADR-0016 Phase 1).
#
# Covers --fallback-model / CEKERNEL_FALLBACK_MODEL passthrough (#529),
# --repo cross-repo issue support (#440), and issue-lock token update
# (ADR-0005 Amendment 1).

load '../helpers/assertions'
load '../helpers/mock-bin'
load '../helpers/mock-claude'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SPAWN_SCRIPT="${CEKERNEL_DIR}/scripts/orchestrator/spawn.sh"
  TMP="$(mktemp -d)"

  # Upstream repo + clone (spawn.sh runs `git fetch origin <base>`)
  git init -q -b main "${TMP}/upstream"
  git -C "${TMP}/upstream" -c user.email=test@test -c user.name=test \
    commit -q --allow-empty -m "init"
  git clone -q "${TMP}/upstream" "${TMP}/repo"

  # Mock gh: spawn.sh reads the title, task-file.sh reads full JSON.
  # Records argv so tests can assert executed effects (ADR-0017).
  GH_ARGS_FILE="${TMP}/gh-args.txt"
  mock_bin gh "echo \"\$*\" >> '${GH_ARGS_FILE}'
if [[ \"\$*\" == *\"-q\"* ]]; then
  echo \"Test issue\"
else
  echo '{\"title\":\"Test issue\",\"body\":\"test body\",\"labels\":[],\"comments\":[]}'
fi"
  # Canonical claude shim: --bg spawn line + agents --json + stop (ADR-0017).
  # With an empty agents queue, capture degrades to the default short ID
  # ("deadbeef") — spawn.sh still succeeds and records the token.
  mock_claude
  ARGS_FILE="${MOCK_CLAUDE_STATE_DIR}/bg-argv.log"

  # Isolation: session/IPC/locks under TMP, trust file, bare auth, backend
  export CEKERNEL_SESSION_ID="test-spawn-fallback-$$"
  export CEKERNEL_VAR_DIR="${TMP}/var"
  unset CEKERNEL_IPC_DIR
  export CLAUDE_JSON="${TMP}/claude.json"
  export ANTHROPIC_API_KEY="test-key-bare"
  export CEKERNEL_BACKEND="headless"

  # Neutral env profiles — plugin defaults (headless.env) must not leak
  # CEKERNEL_FALLBACK_MODEL into tests that assert the unset behavior.
  mkdir -p "${TMP}/envs"
  export _CEKERNEL_PLUGIN_ENVS_DIR="${TMP}/envs"
  export _CEKERNEL_PROJECT_ENVS_DIR="${TMP}/envs"
  export _CEKERNEL_USER_ENVS_DIR="${TMP}/envs"
  unset CEKERNEL_FALLBACK_MODEL CEKERNEL_CLAUDE_SETTINGS
}

teardown() {
  rm -rf "$TMP"
}

# run_spawn [extra-flags...] — run spawn.sh for issue 42 against base main
run_spawn() {
  run bash -c "cd '${TMP}/repo' && bash '${SPAWN_SCRIPT}' --agent worker $* 42 main"
}

@test "spawn.sh --fallback-model forwards the model to claude argv" {
  run_spawn --fallback-model my-fallback
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(tr '\n' ' ' < "$ARGS_FILE")"
  assert_match "claude argv pairs flag with model" "--fallback-model my-fallback" "$argv"
}

@test "spawn.sh forwards CEKERNEL_FALLBACK_MODEL from the environment" {
  export CEKERNEL_FALLBACK_MODEL="env-model"
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(tr '\n' ' ' < "$ARGS_FILE")"
  assert_match "claude argv pairs flag with env model" "--fallback-model env-model" "$argv"
}

@test "spawn.sh --fallback-model overrides CEKERNEL_FALLBACK_MODEL" {
  export CEKERNEL_FALLBACK_MODEL="env-model"
  run_spawn --fallback-model flag-model
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(tr '\n' ' ' < "$ARGS_FILE")"
  assert_match "flag wins over env" "--fallback-model flag-model" "$argv"
  if [[ "$argv" == *"env-model"* ]]; then
    echo "FAIL: env model must not appear when flag is given: ${argv}" >&2
    return 1
  fi
}

@test "spawn.sh omits --fallback-model when nothing is configured" {
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(cat "$ARGS_FILE")"
  if [[ "$argv" == *"--fallback-model"* ]]; then
    echo "FAIL: --fallback-model must not appear by default: ${argv}" >&2
    return 1
  fi
}

# ── Cross-repo issue support (#440) ──

@test "spawn.sh --repo passes --repo to gh issue view" {
  run_spawn --repo acme/planning
  assert_eq "spawn exits 0" "0" "$status"
  local gh_argv
  gh_argv="$(tr '\n' ' ' < "$GH_ARGS_FILE")"
  assert_match "gh argv contains --repo owner/repo" \
    "--repo acme/planning" "$gh_argv"
}

@test "spawn.sh --repo writes repo: field into the task file" {
  run_spawn --repo acme/planning
  assert_eq "spawn exits 0" "0" "$status"
  local task_file="${TMP}/repo/.worktrees/issue/42-test-issue/.cekernel-task.md"
  assert_file_exists "task file created in worktree" "$task_file"
  assert_match "task file has repo field" \
    "repo: acme/planning" "$(cat "$task_file")"
}

@test "spawn.sh --repo references owner/repo#N in the worker prompt" {
  run_spawn --repo acme/planning
  assert_eq "spawn exits 0" "0" "$status"
  wait_for_file "$ARGS_FILE"
  local argv
  argv="$(tr '\n' ' ' < "$ARGS_FILE")"
  assert_match "claude argv references cross-repo issue" \
    "acme/planning#42" "$argv"
}

# ── Base branch propagation (#562) ──

@test "spawn.sh records the base branch in the task file" {
  # Non-default base branch in upstream
  git -C "${TMP}/upstream" branch dev
  run bash -c "cd '${TMP}/repo' && bash '${SPAWN_SCRIPT}' --agent worker 42 dev"
  assert_eq "spawn exits 0" "0" "$status"
  local task_file="${TMP}/repo/.worktrees/issue/42-test-issue/.cekernel-task.md"
  assert_file_exists "task file created in worktree" "$task_file"
  assert_match "task file has base field" "base: dev" "$(cat "$task_file")"
}

@test "spawn.sh records the default base branch (main) in the task file" {
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  local task_file="${TMP}/repo/.worktrees/issue/42-test-issue/.cekernel-task.md"
  assert_file_exists "task file created in worktree" "$task_file"
  assert_match "task file has base field" "base: main" "$(cat "$task_file")"
}

# ── Issue-lock token update (ADR-0005 Amendment 1) ──

@test "spawn.sh updates the issue lock with the captured session token" {
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  local pid_file
  pid_file=$(find "${CEKERNEL_VAR_DIR}/locks" -path "*/42.lock/pid" | head -1)
  assert_file_exists "lock holder file exists" "$pid_file"
  # Empty agents queue → capture degrades to the mock's default short ID
  assert_eq "lock holder is the session token" "deadbeef" "$(cat "$pid_file")"
}

@test "spawn.sh handle file contains the captured session token" {
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  local ipc_dir
  ipc_dir=$(find "${CEKERNEL_VAR_DIR}/ipc" -maxdepth 1 -type d -name "test-spawn-*" | head -1)
  assert_file_exists "handle file exists" "${ipc_dir}/handle-42.worker"
  assert_eq "handle is the session token" "deadbeef" \
    "$(cat "${ipc_dir}/handle-42.worker")"
}

# ── Permission preflight (ADR-0012 Amendment 4, layer 1) ──
# Coarse check: warn when the target repo lacks a usable permissions.allow,
# but never abort the spawn.

# commit_settings <json> — commit .claude/settings.json to upstream so the
# worktree checkout (created from origin/main) contains it
commit_settings() {
  mkdir -p "${TMP}/upstream/.claude"
  printf '%s\n' "$1" > "${TMP}/upstream/.claude/settings.json"
  git -C "${TMP}/upstream" add .claude/settings.json
  git -C "${TMP}/upstream" -c user.email=test@test -c user.name=test \
    commit -q -m "add settings"
}

@test "spawn.sh warns but proceeds when target repo has no .claude/settings.json" {
  run_spawn
  assert_eq "spawn exits 0 (preflight never aborts)" "0" "$status"
  assert_match "warns about missing settings" "permission preflight" "$output"
  wait_for_file "$ARGS_FILE"
}

@test "spawn.sh does not warn when permissions.allow is non-empty" {
  commit_settings '{"permissions": {"allow": ["Bash", "Edit", "Write", "Read"]}}'
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  if [[ "$output" == *"permission preflight"* ]]; then
    echo "FAIL: no preflight warning expected with non-empty allow: ${output}" >&2
    return 1
  fi
}

@test "spawn.sh warns but proceeds when permissions.allow is empty" {
  commit_settings '{"permissions": {"allow": []}}'
  run_spawn
  assert_eq "spawn exits 0 (preflight never aborts)" "0" "$status"
  assert_match "warns about empty allow" "permission preflight" "$output"
  wait_for_file "$ARGS_FILE"
}

@test "spawn.sh without --repo keeps current-repo behavior" {
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"
  local gh_argv
  gh_argv="$(tr '\n' ' ' < "$GH_ARGS_FILE")"
  if [[ "$gh_argv" == *"--repo"* ]]; then
    echo "FAIL: --repo must not appear in gh argv by default: ${gh_argv}" >&2
    return 1
  fi
  local task_file="${TMP}/repo/.worktrees/issue/42-test-issue/.cekernel-task.md"
  assert_file_exists "task file created in worktree" "$task_file"
  if grep -q '^repo:' "$task_file"; then
    echo "FAIL: repo: field must not appear in task file by default" >&2
    return 1
  fi
}

# ── ADR-0020 Phase 1: active_worker_count counts non-TERMINATED state files ──

@test "active_worker_count counts non-TERMINATED state files, not pipes" {
  run_spawn
  assert_eq "spawn exits 0" "0" "$status"

  # After a successful spawn, the state file should be READY (post-spawn)
  # and should count as 1 active worker
  local ipc_dir
  ipc_dir=$(find "${CEKERNEL_VAR_DIR}/ipc" -maxdepth 1 -type d -name "test-spawn-*" | head -1)

  # Verify: state file exists and counts toward the active count
  assert_file_exists "state file exists" "${ipc_dir}/worker-42.state"
  local state_line
  state_line=$(cat "${ipc_dir}/worker-42.state")
  # State should be READY (not TERMINATED)
  assert_match "state is READY" "^READY:" "$state_line"
}

@test "spawn.sh exits 2 when MAX_ORCH_CHILDREN non-TERMINATED state files exist" {
  # First spawn succeeds
  run_spawn
  assert_eq "first spawn exits 0" "0" "$status"

  # Find the IPC dir
  local ipc_dir
  ipc_dir=$(find "${CEKERNEL_VAR_DIR}/ipc" -maxdepth 1 -type d -name "test-spawn-*" | head -1)

  # Create additional non-TERMINATED state files to hit the limit
  # Default MAX_ORCH_CHILDREN is 5, so create 4 more (total 5 with the spawned one)
  for i in 100 101 102 103; do
    echo "RUNNING:2026-07-09T00:00:00Z:phase1:implement" > "${ipc_dir}/worker-${i}.state"
  done

  # Next spawn should fail with exit 2
  run bash -c "cd '${TMP}/repo' && CEKERNEL_MAX_ORCH_CHILDREN=5 bash '${SPAWN_SCRIPT}' --agent worker 43 main"
  assert_eq "spawn exits 2 at capacity" "2" "$status"
}

@test "spawn.sh does not count TERMINATED state files toward capacity" {
  run_spawn
  assert_eq "first spawn exits 0" "0" "$status"

  local ipc_dir
  ipc_dir=$(find "${CEKERNEL_VAR_DIR}/ipc" -maxdepth 1 -type d -name "test-spawn-*" | head -1)

  # Create state files: 3 TERMINATED + 1 RUNNING = only 2 active (inc. issue 42)
  echo "TERMINATED:2026-07-09T00:00:00Z:ci-passed:99" > "${ipc_dir}/worker-100.state"
  echo "TERMINATED:2026-07-09T00:00:00Z:merged:88" > "${ipc_dir}/worker-101.state"
  echo "TERMINATED:2026-07-09T00:00:00Z:crashed:boom" > "${ipc_dir}/worker-102.state"
  echo "RUNNING:2026-07-09T00:00:00Z:phase1:implement" > "${ipc_dir}/worker-103.state"

  # With MAX=3 and 2 active, should succeed
  run bash -c "cd '${TMP}/repo' && CEKERNEL_MAX_ORCH_CHILDREN=3 bash '${SPAWN_SCRIPT}' --agent worker 44 main"
  assert_eq "spawn succeeds with terminated workers not counting" "0" "$status"
}
