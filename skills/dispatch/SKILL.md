---
description: Batch-process open issues with the `ready` label — discover, triage, and delegate to the Orchestrator
argument-hint: "[--env profile] [--label label]"
allowed-tools: Bash, Read, Task(cekernel:orchestrator), Task(orchestrator)
---

# /dispatch

Discovers open issues labeled `ready`, triages them, and delegates to the Orchestrator agent for parallel processing.

## Usage

No arguments required — by default, picks up all open issues with the `ready` label.

Optional flags:

- `--env <profile>` — Select an env profile (default: `default`). Available profiles: `default`, `headless`, `ci`, or any custom profile in `.cekernel/envs/`.
- `--label <label>` — Override the target label (default: `ready`).

Examples:

```
/dispatch
/dispatch --env headless
/dispatch --label sprint-3
/dispatch --env ci --label ready
```

Note: In plugin mode, `/cekernel:dispatch` also works.

## Idempotency

- Worker merges a PR with `closes #N` which auto-closes the issue
- Next dispatch run uses `--state open`, so closed issues are excluded
- No label manipulation needed — pure filter, zero side effects

## Workflow

### Step 0: Detect Agent Names

Detect whether cekernel is running as a plugin or locally using file-based detection (ADR-0009).

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set agent names based on the result:
   - If `CEKERNEL_NS=local`: `CEKERNEL_AGENT_ORCHESTRATOR=orchestrator`, `CEKERNEL_AGENT_WORKER=worker`, `CEKERNEL_AGENT_REVIEWER=reviewer`
   - If `CEKERNEL_NS=plugin`: `CEKERNEL_AGENT_ORCHESTRATOR=cekernel:orchestrator`, `CEKERNEL_AGENT_WORKER=cekernel:worker`, `CEKERNEL_AGENT_REVIEWER=cekernel:reviewer`

Store these values for use in subsequent steps.

Also resolve the cekernel scripts path for lock checking and Orchestrator propagation:

```bash
CEKERNEL_SCRIPTS="$(cd -P "${CLAUDE_SKILL_DIR}/../../scripts" && pwd)"
```

### Step 1: Discover Issues

Fetch all open issues with the target label:

```bash
gh issue list --label <label> --state open --json number,title --jq '.[] | "\(.number)\t\(.title)"'
```

If no issues are found, report to the user and exit — there is nothing to process.

### Step 1.5: Lock Filter

Filter out issues already being processed by an active Worker:

```bash
source "${CEKERNEL_SCRIPTS}/shared/issue-lock.sh"
issue_lock_check "$(git rev-parse --show-toplevel)" <issue-number>
# exit 0 = locked (skip), exit 1 = unlocked (proceed)
```

Remove locked issues from the candidate list before triage. Report skipped issues to the user.

### Step 2: Triage

Read `skills/references/triage.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/triage.md`) and follow the triage protocol for each discovered issue.

### Step 3: Confirm with User

Present the triaged issue list to the user for confirmation before delegating:

```
Found N issues with label "ready":
  #42  Fix login timeout
  #55  Add dark mode support
  #61  Update dependencies

Proceed with delegation to Orchestrator? (y/n)
```

Wait for user confirmation. If the user declines, exit without action.

### Step 4: Parse `--env`, Initialize Session, and Launch Orchestrator Agent

If `--env <profile>` was specified, set `CEKERNEL_ENV` to the given profile name. If not specified, default to `default`.

**Initialize cekernel session and persist Claude Code session ID** — Run the following in a **single** Bash tool call. This generates `CEKERNEL_SESSION_ID` (format: `{repo}-{hex8}`), writes repo metadata for `orchctrl ls`, and separately persists the Claude Code session UUID for `/postmortem`:

```bash
# 1. Generate CEKERNEL_SESSION_ID ({repo}-{hex8} format)
source "${CEKERNEL_SCRIPTS}/shared/load-env.sh"
source "${CEKERNEL_SCRIPTS}/shared/session-id.sh"
mkdir -p "$CEKERNEL_IPC_DIR"

# 2. Write repo metadata for orchctrl (org/repo format)
_url="$(git config --get remote.origin.url)"
_path="${_url#*:}"; _path="${_path#*//}"; _path="${_path%.git}"
_REPO_SLUG="${_path#*/}"
echo "$_REPO_SLUG" > "${CEKERNEL_IPC_DIR}/repo"

# 3. Persist Claude Code session ID (UUID — separate from CEKERNEL_SESSION_ID)
source "${CEKERNEL_SCRIPTS}/shared/claude-session-id.sh"
_PROJECT_ROOT="$(git rev-parse --show-toplevel)"
_CLAUDE_SID=$(claude_session_id_discover "$_PROJECT_ROOT") && claude_session_id_persist "$_CLAUDE_SID" || echo "warn: Claude session ID discovery failed (non-fatal)" >&2

# 4. Output CEKERNEL_SESSION_ID for prompt construction
echo "CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID}"
```

**IMPORTANT**: `CEKERNEL_SESSION_ID` and `CLAUDE_SESSION_ID` are distinct values with different purposes:
- `CEKERNEL_SESSION_ID` — cekernel's session identifier (`{repo}-{hex8}`), used for IPC directory and script coordination
- `CLAUDE_SESSION_ID` — Claude Code's internal UUID, used only for `/postmortem` transcript lookup

Capture `CEKERNEL_SESSION_ID` from the Bash output (the line `CEKERNEL_SESSION_ID=...`) and use it in the Orchestrator prompt. Do **NOT** use the Claude Code session UUID as `CEKERNEL_SESSION_ID`.

If Claude Code session ID discovery fails (e.g., no `.jsonl` files found), continue — it is optional for Orchestrator operation.

Launch the Orchestrator subagent via the Task tool:

- `subagent_type`: Use `CEKERNEL_AGENT_ORCHESTRATOR` determined in Step 0
- `run_in_background`: `true`
- `prompt`: Include issue numbers, execution order (if determined in Step 2), `CEKERNEL_SESSION_ID` value (from the Bash output above — must be `{repo}-{hex8}` format, **not** a UUID), `CEKERNEL_ENV` value, `CEKERNEL_SCRIPTS` value, `CEKERNEL_AGENT_WORKER` value, and `CEKERNEL_AGENT_REVIEWER` value. Instruct the Orchestrator to use `CEKERNEL_SCRIPTS` as prefix for all script calls, pass `export CEKERNEL_SESSION_ID=<ID>` and `export CEKERNEL_ENV=<profile>` in **all script invocations** (not just `spawn-worker.sh`, but also `watch.sh`, `process-status.sh`, `cleanup-worktree.sh`, `spawn-reviewer.sh`, etc.), `export CEKERNEL_AGENT_WORKER=<agent-name>` in all `spawn-worker.sh` invocations, and `export CEKERNEL_AGENT_REVIEWER=<agent-name>` in all `spawn-reviewer.sh` invocations.

**MUST NOT**: Do not include Agent tool language (`subagent_type`, `Agent(worker)`, `Agent(reviewer)`, etc.) in the Orchestrator prompt. Workers and Reviewers are spawned by the Orchestrator via `spawn-worker.sh` / `spawn-reviewer.sh` (Bash), following its own agent definition. The skill must not dictate how the Orchestrator launches subprocesses.

The Orchestrator autonomously executes:

1. Issue verification and triage (FAIL for ambiguous issues)
2. Worker spawning (with `CEKERNEL_ENV` propagated)
3. Completion monitoring
4. Review coordination (spawn Reviewer + FIFO on ci-passed)
5. Merge decision and cleanup
