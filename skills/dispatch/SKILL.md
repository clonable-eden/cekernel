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

Also resolve the cekernel scripts path for lock checking:
- If `CEKERNEL_NS=local`: `CEKERNEL_SCRIPTS="$(git rev-parse --show-toplevel)/scripts"`
- If `CEKERNEL_NS=plugin`: `CEKERNEL_SCRIPTS="$(dirname "$(which spawn-worker.sh 2>/dev/null)")/../.."/scripts`

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

### Step 4: Parse `--env` and Launch Orchestrator Agent

If `--env <profile>` was specified, set `CEKERNEL_ENV` to the given profile name. If not specified, default to `default`.

Launch the Orchestrator subagent via the Task tool:

- `subagent_type`: Use `CEKERNEL_AGENT_ORCHESTRATOR` determined in Step 0
- `run_in_background`: `true`
- `prompt`: Include issue numbers, execution order (if determined in Step 2), `CEKERNEL_ENV` value, `CEKERNEL_AGENT_WORKER` value, and `CEKERNEL_AGENT_REVIEWER` value. Instruct the Orchestrator to pass `export CEKERNEL_ENV=<profile>` in **all script invocations** (not just `spawn-worker.sh`, but also `watch-worker.sh`, `worker-status.sh`, `cleanup-worktree.sh`, etc.), `export CEKERNEL_AGENT_WORKER=<agent-name>` in all `spawn-worker.sh` invocations, and use `CEKERNEL_AGENT_REVIEWER` as the `subagent_type` when launching the Reviewer.

Example prompt fragment:

```
Process issues: #42 #55 #61
Use CEKERNEL_ENV=default, CEKERNEL_AGENT_WORKER=cekernel:worker, and CEKERNEL_AGENT_REVIEWER=cekernel:reviewer.
Pass CEKERNEL_ENV to ALL script calls (spawn-worker.sh, watch-worker.sh, worker-status.sh, cleanup-worktree.sh, etc.):
export CEKERNEL_SESSION_ID=<ID> && export CEKERNEL_ENV=default && export CEKERNEL_AGENT_WORKER=cekernel:worker && spawn-worker.sh 42
export CEKERNEL_SESSION_ID=<ID> && export CEKERNEL_ENV=default && watch-worker.sh 42
When a Worker completes with ci-passed, launch the Reviewer with subagent_type=cekernel:reviewer.
```

The Orchestrator autonomously executes:

1. Issue verification and triage (FAIL for ambiguous issues)
2. Worker spawning (with `CEKERNEL_ENV` propagated)
3. Completion monitoring
4. Review coordination (Reviewer subagent on ci-passed)
5. Merge decision and cleanup
