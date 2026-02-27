---
description: Delegate issues to the Orchestrator agent for parallel processing after priority assessment
allowed-tools: Bash, Read, Task(cekernel:orchestrator)
---

# /orchestrate

Delegates specified issues to the Orchestrator agent for parallel processing using git worktrees + WezTerm windows.

## Usage

Receive issue numbers (single or multiple) from the user.

## Workflow

### Step 1: Issue Triage and Priority Assessment

Check each issue's content with `gh issue view` and verify:

1. **Clarity of requirements**: Are the required changes specifically described?
2. **Scope**: Can the implementation scope be identified?

If any issue has ambiguous or insufficient requirements, report to the user and confirm action (fix the issue, skip, proceed, etc.). If requirements become clear through user interaction, add supplementary information as a comment on the issue via `gh issue comment` so the Worker can work accurately, then delegate to the Orchestrator.

For multiple issues, additionally:

3. Analyze dependencies between issues (does completing A require B to finish first?)
4. If dependencies exist, organize into phases and present the execution order to the user for confirmation

### Step 2: Launch Orchestrator Agent

Launch the `cekernel:orchestrator` subagent via the Task tool:

- `subagent_type`: `cekernel:orchestrator`
- `run_in_background`: `true`
- `prompt`: Include issue numbers, base branch (if specified), and execution order (if determined in Step 1)

The Orchestrator autonomously executes:

1. Issue verification and triage (FAIL for ambiguous issues)
2. Worker spawning
3. Completion monitoring
4. Cleanup

### Step 3: Report Results

The Orchestrator will notify on completion via background task notification.
Report the results to the user at that time.
