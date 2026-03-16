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

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set agent names based on the result:
   - If `CEKERNEL_NS=local`: `CEKERNEL_AGENT_ORCHESTRATOR=orchestrator`, `CEKERNEL_AGENT_WORKER=worker`, `CEKERNEL_AGENT_REVIEWER=reviewer`
   - If `CEKERNEL_NS=plugin`: `CEKERNEL_AGENT_ORCHESTRATOR=cekernel:orchestrator`, `CEKERNEL_AGENT_WORKER=cekernel:worker`, `CEKERNEL_AGENT_REVIEWER=cekernel:reviewer`

Store these values for use in subsequent steps.

Also resolve the cekernel scripts path for lock checking and Orchestrator propagation:

```bash
CEKERNEL_SCRIPTS="$(cd "${CLAUDE_SKILL_DIR}/../../scripts" && pwd)"
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

### Step 2: Parse `--env`, Persist Claude Code Session ID, and Launch Orchestrator Agent

If `--env <profile>` was specified, set `CEKERNEL_ENV` to the given profile name. If not specified, default to `default`.

**Persist Claude Code Session ID** — Before launching the Orchestrator, discover and save the current Claude Code session ID so that `/postmortem` can later locate Orchestrator transcripts:

```bash
source "${CEKERNEL_SCRIPTS}/shared/load-env.sh"
source "${CEKERNEL_SCRIPTS}/shared/session-id.sh"
source "${CEKERNEL_SCRIPTS}/shared/claude-session-id.sh"
mkdir -p "$CEKERNEL_IPC_DIR"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
CLAUDE_SESSION_ID=$(claude_session_id_discover "$PROJECT_ROOT") && claude_session_id_persist "$CLAUDE_SESSION_ID"
```

If discovery fails (e.g., no `.jsonl` files found), log a warning and continue — the session ID is optional for Orchestrator operation.

Launch the Orchestrator subagent via the Task tool:

- `subagent_type`: Use `CEKERNEL_AGENT_ORCHESTRATOR` determined in Step 0
- `run_in_background`: `true`
- `prompt`: Include issue numbers, base branch (if specified), execution order (if determined in Step 1), `CEKERNEL_SESSION_ID` value, `CEKERNEL_ENV` value, `CEKERNEL_SCRIPTS` value, `CEKERNEL_AGENT_WORKER` value, and `CEKERNEL_AGENT_REVIEWER` value. Instruct the Orchestrator to use `CEKERNEL_SCRIPTS` as prefix for all script calls, pass `export CEKERNEL_ENV=<profile>` in **all script invocations** (not just `spawn-worker.sh`, but also `watch.sh`, `process-status.sh`, `cleanup-worktree.sh`, `spawn-reviewer.sh`, etc.), `export CEKERNEL_AGENT_WORKER=<agent-name>` in all `spawn-worker.sh` invocations, and `export CEKERNEL_AGENT_REVIEWER=<agent-name>` in all `spawn-reviewer.sh` invocations.

**MUST NOT**: Do not include Agent tool language (`subagent_type`, `Agent(worker)`, `Agent(reviewer)`, etc.) in the Orchestrator prompt. Workers and Reviewers are spawned by the Orchestrator via `spawn-worker.sh` / `spawn-reviewer.sh` (Bash), following its own agent definition. The skill must not dictate how the Orchestrator launches subprocesses.

The Orchestrator autonomously executes:

1. Issue verification and triage (FAIL for ambiguous issues)
2. Worker spawning (with `CEKERNEL_ENV` propagated)
3. Completion monitoring
4. Review coordination (spawn Reviewer + FIFO on ci-passed)
5. Merge decision and cleanup

