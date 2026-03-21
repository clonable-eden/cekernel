---
description: Batch-process open issues with the `ready` label — discover, triage, and delegate to the Orchestrator
argument-hint: "[--yes] [--env profile] [--label label]"
allowed-tools: Bash, Read
---

# /dispatch

Discovers open issues labeled `ready`, triages them, and delegates to the Orchestrator agent for parallel processing.

## Usage

No arguments required — by default, picks up all open issues with the `ready` label.

Optional flags:

- `--yes`, `-y` — Skip the user confirmation step (Step 3) and proceed directly to delegation. Required for non-interactive execution (cron, at).
- `--env <profile>` — Select an env profile (default: `default`). Available profiles: `default`, `headless`, `ci`, or any custom profile in `.cekernel/envs/`.
- `--label <label>` — Override the target label (default: `ready`).

Examples:

```
/dispatch
/dispatch --yes
/dispatch -y --env headless --label sprint-3
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

If `--yes` (or `-y`) was specified, skip the confirmation prompt and proceed directly to Step 4.

Otherwise, present the triaged issue list to the user for confirmation before delegating:

```
Found N issues with label "ready":
  #42  Fix login timeout
  #55  Add dark mode support
  #61  Update dependencies

Proceed with delegation to Orchestrator? (y/n)
```

Wait for user confirmation. If the user declines, exit without action.

### Step 3.5: Orchestrator Concurrency Guard

Before launching the Orchestrator, check the current number of running orchestrators against `CEKERNEL_MAX_ORCHESTRATORS`:

```bash
ORCHCTL="${CEKERNEL_SCRIPTS}/ctl/orchctl.sh"
CURRENT_ORCH=$(bash "$ORCHCTL" count 2>/dev/null)
source "${CEKERNEL_SCRIPTS}/shared/load-env.sh"
MAX_ORCH="${CEKERNEL_MAX_ORCHESTRATORS:-3}"
echo "orchestrators: ${CURRENT_ORCH}/${MAX_ORCH}"
```

If `CURRENT_ORCH >= MAX_ORCH`:

1. **Stop dispatching** — do NOT launch the Orchestrator. Any remaining issues are left for the next `/dispatch` run.
2. **Notify the user** via desktop notification:

```bash
source "${CEKERNEL_SCRIPTS}/shared/desktop-notify.sh"
desktop_notify "cekernel: dispatch stopped" "Orchestrator limit reached (${CURRENT_ORCH}/${MAX_ORCH}). Remaining issues deferred."
```

3. Report to the user which issues were dispatched (if any) and which were deferred due to the limit.
4. Exit — do not proceed to Step 4.

If `CURRENT_ORCH < MAX_ORCH`, proceed to Step 4.

### Step 4: Parse `--env`, Initialize Session, and Launch Orchestrator Process

If `--env <profile>` was specified, set `CEKERNEL_ENV` to the given profile name. If not specified, default to `default`.

**Initialize cekernel session** — Run the following in a **single** Bash tool call. This generates `CEKERNEL_SESSION_ID` (format: `{repo}-{hex8}`) and writes repo metadata for `orchctl ls`:

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

# 3. Output CEKERNEL_SESSION_ID for prompt construction
echo "CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID}"
```

Capture `CEKERNEL_SESSION_ID` from the Bash output (the line `CEKERNEL_SESSION_ID=...`) and use it in the Orchestrator prompt.

Note: Claude Code session ID (`orchestrator.claude-session-id`) persistence is handled by the Orchestrator itself after startup. The dispatch skill does not persist it because the skill's UUID differs from the Orchestrator's UUID (the Orchestrator runs as a separate `claude -p --agent` process).

**Construct the Orchestrator prompt** from the following template. Replace `<placeholders>` with actual values determined in previous steps:

```
Process the following issues: <#N title, #M title, ...>
<Execution order if determined in Step 2, otherwise omit this line>

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
