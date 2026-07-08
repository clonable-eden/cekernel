# Orchestrator Launch Protocol

Shared protocol for skills that delegate issues to the Orchestrator (`/orchestrate`, `/dispatch`). The invoking skill defines *which* issues to process; this reference defines *how* to launch the Orchestrator for them.

## Step A: Detect Agent Names and Script Path

Detect plugin vs local mode with file-based detection (ADR-0009):

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set agent names:
   - `CEKERNEL_NS=local` → `CEKERNEL_AGENT_ORCHESTRATOR=orchestrator`, `CEKERNEL_AGENT_WORKER=worker`, `CEKERNEL_AGENT_REVIEWER=reviewer`
   - `CEKERNEL_NS=plugin` → the same names prefixed with `cekernel:`

Resolve the cekernel scripts path for lock checking and Orchestrator propagation:

```bash
CEKERNEL_SCRIPTS="$(cd -P "${CLAUDE_SKILL_DIR}/../../scripts" && pwd)"
```

## Step B: Lock Filter

Filter out issues already being processed by an active Worker, and report skipped issues to the user:

```bash
source "${CEKERNEL_SCRIPTS}/shared/issue-lock.sh"
issue_lock_check "$(git rev-parse --show-toplevel)" <issue-number>
# exit 0 = locked (skip), exit 1 = unlocked (proceed)
```

## Step C: Orchestrator Concurrency Guard

Check running orchestrators against the limit before launching:

```bash
ORCHCTL="${CEKERNEL_SCRIPTS}/ctl/orchctl.sh"
CURRENT_ORCH=$(bash "$ORCHCTL" count 2>/dev/null)
source "${CEKERNEL_SCRIPTS}/shared/load-env.sh"
MAX_ORCH="${CEKERNEL_MAX_ORCHESTRATORS:-3}"
echo "orchestrators: ${CURRENT_ORCH}/${MAX_ORCH}"
```

If `CURRENT_ORCH >= MAX_ORCH`, follow the invoking skill's over-limit policy. Otherwise proceed.

## Step D: Initialize Session

If `--env <profile>` was specified, set `CEKERNEL_ENV` to it (default: `default`).

Run the following in a **single** Bash tool call — it generates `CEKERNEL_SESSION_ID` (`{repo}-{hex8}` format) and writes repo metadata for `orchctl ls`:

```bash
source "${CEKERNEL_SCRIPTS}/shared/load-env.sh"
unset CEKERNEL_SESSION_ID          # Orchestrator launch = new session boundary (#622)
source "${CEKERNEL_SCRIPTS}/shared/session-id.sh"
mkdir -p "$CEKERNEL_IPC_DIR"

_url="$(git config --get remote.origin.url)"
_path="${_url#*:}"; _path="${_path#*//}"; _path="${_path%.git}"
echo "${_path#*/}" > "${CEKERNEL_IPC_DIR}/repo"

echo "CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID}"
```

Capture `CEKERNEL_SESSION_ID` from the output line. It must be the `{repo}-{hex8}` value, **not** the Claude Code session UUID. (The Claude Code session ID is captured and persisted by `spawn-orchestrator.sh` itself — neither the skill nor the Orchestrator writes it.)

## Step E: Construct the Prompt and Launch

Prompt template — replace `<placeholders>` with actual values:

```
Process the following issues: <#N title, #M title, ...>
<Execution order if determined during triage, otherwise omit this line>
<Base branch: <branch> if specified, otherwise omit this line>
<Issue repo: <owner/repo> — pass --repo <owner/repo> to spawn-worker.sh and to issue-related gh commands. Only for cross-repo issues, otherwise omit this line>

Environment values to propagate in ALL script invocations:
- CEKERNEL_SESSION_ID=<session-id>
- CEKERNEL_ENV=<profile>
- CEKERNEL_SCRIPTS=<scripts-path>
- CEKERNEL_AGENT_WORKER=<worker-agent-name>
- CEKERNEL_AGENT_REVIEWER=<reviewer-agent-name>
```

**MUST NOT**: do not include Worker spawn instructions using Agent tool language (`subagent_type`, `Agent(worker)`, etc.) in the prompt. Workers are spawned by the Orchestrator via `spawn-worker.sh` (Bash); the Reviewer is invoked by the Orchestrator itself as a subagent, following its own agent definition.

Launch the Orchestrator as an independent process:

```bash
export CEKERNEL_SESSION_ID=<session-id> && \
export CEKERNEL_ENV=<profile> && \
export CEKERNEL_AGENT_ORCHESTRATOR=<agent-name> && \
export CEKERNEL_AGENT_WORKER=<agent-name> && \
export CEKERNEL_AGENT_REVIEWER=<agent-name> && \
"${CEKERNEL_SCRIPTS}/ctl/spawn-orchestrator.sh" "<prompt>"
```

The script launches a `claude --bg --agent` background session supervised by the on-demand daemon and returns the captured Claude Code session token on stdout. The Orchestrator then autonomously executes: triage → Worker spawning → completion monitoring → review coordination → merge decision and cleanup.
