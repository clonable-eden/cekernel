---
description: Delegate issues to the Orchestrator agent for parallel processing after priority assessment
argument-hint: "[--env profile] <issue-numbers>"
allowed-tools: Bash, Read
---

# /orchestrate

Delegates specified issues to the Orchestrator agent for parallel processing using git worktrees + WezTerm windows.

## Usage

Receive issue numbers (single or multiple) from the user.

Optional flags:

- `--env <profile>` — Select an env profile (default: `default`). Available profiles: `default`, `headless`, `ci`, or any custom profile in `.cekernel/envs/`.

Examples:

```
/orchestrate #108
/orchestrate --env headless #108 #109
/orchestrate --env ci #42
```

Note: In plugin mode, `/cekernel:orchestrate` also works.

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

### Step 1: Lock Filter and Triage

First, filter out issues already being processed by an active Worker:

```bash
source "${CEKERNEL_SCRIPTS}/shared/issue-lock.sh"
issue_lock_check "$(git rev-parse --show-toplevel)" <issue-number>
# exit 0 = locked (skip), exit 1 = unlocked (proceed)
```

Remove locked issues from the candidate list and report skipped issues to the user.

Then, read `skills/references/triage.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/triage.md`) and follow the triage protocol for each remaining issue.

After triage, delegate to the Orchestrator.

### Step 2: Parse `--env`, Initialize Session, and Launch Orchestrator Process

If `--env <profile>` was specified, set `CEKERNEL_ENV` to the given profile name. If not specified, default to `default`.

**Initialize cekernel session and persist Claude Code session ID** — Run the following in a **single** Bash tool call. This generates `CEKERNEL_SESSION_ID` (format: `{repo}-{hex8}`), writes repo metadata for `orchctl ls`, and separately persists the Claude Code session UUID for `/postmortem`:

```bash
# 1. Generate CEKERNEL_SESSION_ID ({repo}-{hex8} format)
source "${CEKERNEL_SCRIPTS}/shared/load-env.sh"
source "${CEKERNEL_SCRIPTS}/shared/session-id.sh"
mkdir -p "$CEKERNEL_IPC_DIR"

# 2. Write repo metadata for orchctl (org/repo format)
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

**Construct the Orchestrator prompt** from the following template. Replace `<placeholders>` with actual values determined in previous steps:

```
Process the following issues: <#N title, #M title, ...>
<Execution order if determined in Step 1, otherwise omit this line>
<Base branch: <branch> if specified, otherwise omit this line>

Environment values to propagate in ALL script invocations:
- CEKERNEL_SESSION_ID=<session-id>
- CEKERNEL_ENV=<profile>
- CEKERNEL_SCRIPTS=<scripts-path>
- CEKERNEL_AGENT_WORKER=<worker-agent-name>
- CEKERNEL_AGENT_REVIEWER=<reviewer-agent-name>
```

**IMPORTANT**: `CEKERNEL_SESSION_ID` must be `{repo}-{hex8}` format from the Bash output above, **not** the Claude Code session UUID.

**MUST NOT**: Do not include Agent tool language (`subagent_type`, `Agent(worker)`, `Agent(reviewer)`, etc.) in the prompt. Workers and Reviewers are spawned by the Orchestrator via `spawn-worker.sh` / `spawn-reviewer.sh` (Bash), following its own agent definition.

**Launch the Orchestrator as an independent OS process** via `spawn-orchestrator.sh`:

```bash
export CEKERNEL_SESSION_ID=<session-id> && \
export CEKERNEL_ENV=<profile> && \
export CEKERNEL_AGENT_ORCHESTRATOR=<agent-name> && \
export CEKERNEL_AGENT_WORKER=<agent-name> && \
export CEKERNEL_AGENT_REVIEWER=<agent-name> && \
"${CEKERNEL_SCRIPTS}/ctl/spawn-orchestrator.sh" "<prompt>"
```

The script launches the Orchestrator as a background `claude -p --agent` process that runs independently of the parent session. The Orchestrator PID is returned on stdout.

The Orchestrator autonomously executes:

1. Issue verification and triage (FAIL for ambiguous issues)
2. Worker spawning (with `CEKERNEL_ENV` propagated)
3. Completion monitoring
4. Review coordination (spawn Reviewer + FIFO on ci-passed)
5. Merge decision and cleanup

