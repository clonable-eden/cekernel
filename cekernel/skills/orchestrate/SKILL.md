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
/cekernel:orchestrate #108
/cekernel:orchestrate --env headless #108 #109
/cekernel:orchestrate --env ci #42
```

## Workflow

### Step 0: Detect Agent Names

Determine whether cekernel is running as a plugin (with namespace prefix) or locally (without prefix).

Run the following Bash command:

```bash
test -n "${CLAUDE_PLUGIN_ROOT:-}" && echo "plugin" || echo "local"
```

- If `plugin`: `CEKERNEL_AGENT_ORCHESTRATOR=cekernel:orchestrator`, `CEKERNEL_AGENT_WORKER=cekernel:worker`
- If `local`: `CEKERNEL_AGENT_ORCHESTRATOR=orchestrator`, `CEKERNEL_AGENT_WORKER=worker`

Store these values for use in subsequent steps.

### Step 1: Issue Triage and Priority Assessment

Check each issue's content with `gh issue view` and verify:

1. **Clarity of requirements**: Are the required changes specifically described?
2. **Scope**: Can the implementation scope be identified?

If any issue has ambiguous or insufficient requirements, report to the user and confirm action (fix the issue, skip, proceed, etc.). If requirements become clear through user interaction, add supplementary information as a comment on the issue via `gh issue comment` so the Worker can work accurately, then delegate to the Orchestrator.

For multiple issues, additionally:

3. Analyze dependencies between issues (does completing A require B to finish first?)
4. If dependencies exist, organize into phases and present the execution order to the user for confirmation

### Step 2: Parse `--env` and Launch Orchestrator Agent

If `--env <profile>` was specified, set `CEKERNEL_ENV` to the given profile name. If not specified, default to `default`.

Launch the Orchestrator subagent via the Task tool:

- `subagent_type`: Use `CEKERNEL_AGENT_ORCHESTRATOR` determined in Step 0
- `run_in_background`: `true`
- `prompt`: Include issue numbers, base branch (if specified), execution order (if determined in Step 1), `CEKERNEL_ENV` value, and `CEKERNEL_AGENT_WORKER` value. Instruct the Orchestrator to pass `export CEKERNEL_ENV=<profile>` and `export CEKERNEL_AGENT_WORKER=<agent-name>` in all `spawn-worker.sh` invocations.

Example prompt fragment:

```
Use CEKERNEL_ENV=headless and CEKERNEL_AGENT_WORKER=cekernel:worker when spawning workers:
export CEKERNEL_SESSION_ID=<ID> && export CEKERNEL_ENV=headless && export CEKERNEL_AGENT_WORKER=cekernel:worker && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh 108
```

The Orchestrator autonomously executes:

1. Issue verification and triage (FAIL for ambiguous issues)
2. Worker spawning (with `CEKERNEL_ENV` propagated)
3. Completion monitoring
4. Cleanup

