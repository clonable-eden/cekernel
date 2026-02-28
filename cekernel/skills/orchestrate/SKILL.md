---
description: Delegate issues to the Orchestrator agent for parallel processing after priority assessment
argument-hint: "[--env profile] <issue-numbers>"
allowed-tools: Bash, Read, Task(cekernel:orchestrator), Task(orchestrator)
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

1. Read `cekernel/skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/cekernel/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set agent names based on the result:
   - If `CEKERNEL_NS=local`: `CEKERNEL_AGENT_ORCHESTRATOR=orchestrator`, `CEKERNEL_AGENT_WORKER=worker`
   - If `CEKERNEL_NS=plugin`: `CEKERNEL_AGENT_ORCHESTRATOR=cekernel:orchestrator`, `CEKERNEL_AGENT_WORKER=cekernel:worker`

Store these values for use in subsequent steps.

### Step 1: Issue Triage and Priority Assessment

Read `cekernel/skills/references/triage.md` from the repository root (`$(git rev-parse --show-toplevel)/cekernel/skills/references/triage.md`) and follow the triage protocol for each issue.

After triage, delegate to the Orchestrator.

### Step 2: Parse `--env` and Launch Orchestrator Agent

If `--env <profile>` was specified, set `CEKERNEL_ENV` to the given profile name. If not specified, default to `default`.

Launch the Orchestrator subagent via the Task tool:

- `subagent_type`: Use `CEKERNEL_AGENT_ORCHESTRATOR` determined in Step 0
- `run_in_background`: `true`
- `prompt`: Include issue numbers, base branch (if specified), execution order (if determined in Step 1), `CEKERNEL_ENV` value, and `CEKERNEL_AGENT_WORKER` value. Instruct the Orchestrator to pass `export CEKERNEL_ENV=<profile>` and `export CEKERNEL_AGENT_WORKER=<agent-name>` in all `spawn-worker.sh` invocations.

Example prompt fragment:

```
Use CEKERNEL_ENV=headless and CEKERNEL_AGENT_WORKER=cekernel:worker when spawning workers:
export CEKERNEL_SESSION_ID=<ID> && export CEKERNEL_ENV=headless && export CEKERNEL_AGENT_WORKER=cekernel:worker && spawn-worker.sh 108
```

The Orchestrator autonomously executes:

1. Issue verification and triage (FAIL for ambiguous issues)
2. Worker spawning (with `CEKERNEL_ENV` propagated)
3. Completion monitoring
4. Cleanup

