# Claude Code Platform Constraints

> Reference document for architectural decisions involving Claude Code.
> cekernel runs on Claude Code as its execution platform. Designs that ignore
> these constraints produce architectures that are correct in theory but
> unimplementable in practice.
>
> **Staleness warning**: Claude Code is actively evolving. Constraints listed
> here reflect the platform as observed through early 2026. When making
> architectural decisions, verify that constraints still hold — especially
> those marked with a confidence level below "Stable".

## Execution Model

### Turn-Based Synchronous Execution

**Confidence: Stable**

Claude Code operates as a synchronous, turn-based agent. Each turn consists of:

1. The model generates a response (which may include tool calls)
2. Tool calls are executed
3. Results are returned to the model
4. The model generates the next response

There is **no mechanism for true mid-turn interruption**. Once a turn begins,
it runs to completion before the agent can observe new information.

**Implications for cekernel**:
- Cooperative signal checking at phase boundaries is the correct pattern
  (not real-time signal handling)
- Long-running tool calls (e.g., `gh pr checks --watch`) block the agent
  from observing anything else until they complete
- Design for "check at natural pauses" rather than "interrupt at any time"

**Reference**: [anthropics/claude-code#3455](https://github.com/anthropics/claude-code/issues/3455)

### Background Tasks

**Confidence: Evolving**

Claude Code supports `run_in_background` for Bash tasks. Background task
completion notifications are queued and delivered at the next turn boundary.

Known characteristics:
- Notifications are cooperative, not preemptive — they arrive between turns,
  not during them
- Reliability of notifications has known issues
- Background tasks are useful for long polling but should not be relied upon
  as the sole mechanism for critical signals

**Implications for cekernel**:
- Background watchers can improve signal detection latency (seconds vs minutes)
  but must not replace phase-boundary checks as the reliable baseline
- Design with the assumption that background notifications may be delayed or missed

**References**:
[anthropics/claude-code#21048](https://github.com/anthropics/claude-code/issues/21048),
[anthropics/claude-code#20525](https://github.com/anthropics/claude-code/issues/20525)

## Agent Architecture

### Single-Threaded Agent

**Confidence: Stable**

Each Claude Code session runs a single agent. There is no built-in mechanism
for an agent to spawn peer agents within the same session. Multi-agent
coordination requires external orchestration (separate terminal sessions,
separate processes).

**Implications for cekernel**:
- The Orchestrator/Worker separation maps correctly to separate sessions
- Worker isolation via git worktrees aligns with "one agent, one workspace"
- Inter-agent communication must use external mechanisms (files, FIFOs)

### Subagent (Task) Tool

**Confidence: Evolving**

The `Task` tool spawns a subagent with its own context window. The parent
agent blocks until the subagent completes. Subagents inherit the parent's
tool permissions but have a separate conversation history.

Known characteristics:
- Subagents cannot communicate with the parent during execution
- The parent receives only the subagent's final output
- Subagent context windows are independent (no shared memory)

**Implications for cekernel**:
- Task-based delegation is fire-and-forget from the parent's perspective
- Status updates from subagents require external side-channels (files, issues)

### Subagent Nesting Limitation

**Confidence: Stable**

Claude Code does not support deeply nested subagent hierarchies reliably.
When a skill spawns an agent (level 1), and that agent spawns a further
subagent (level 2), reliability degrades. Context exhaustion, communication
failures, and unexpected behavior become common at nesting depth ≥ 2.

**Implications for cekernel**:
- The `/orchestrate` skill already uses the Orchestrator as a subagent (level 1).
  Spawning the Reviewer as a further nested subagent (level 2) is unreliable
- The spawn + FIFO pattern avoids nesting entirely: the Reviewer runs as an
  independent process, communicating via FIFO instead of subagent return values
- Design preference: independent processes with FIFO IPC over nested subagents

### Subagent Information Propagation

**Confidence: Stable**

The `prompt` text is the only channel for passing information to a subagent.
There is no mechanism to:
- Set environment variables in the subagent's session
- Specify the subagent's working directory
- Pass structured data outside the prompt string

The subagent also has no built-in self-identification: there is no
`CLAUDE_AGENT_NAME` or equivalent variable that tells the subagent what
role it was spawned for.

**Reference**: [anthropics/claude-code#6885](https://github.com/anthropics/claude-code/issues/6885)

**Implications for cekernel**:
- All context (issue number, session ID, env profile name, worktree path)
  must be serialized into the prompt string
- Workers determine their worktree path from `pwd` rather than a passed variable
- Role identification relies on the agent markdown preamble, not runtime metadata

### Context Window Limits

**Confidence: Stable**

Each agent session has a finite context window. Long conversations cause
older context to be summarized or evicted. There is no persistent memory
across sessions beyond what is written to files.

**Implications for cekernel**:
- Workers must write progress to durable storage (git commits, issue comments)
  not rely on conversation history surviving
- The checkpoint mechanism (`.cekernel-checkpoint.md`) correctly externalizes
  state to the filesystem
- Task files (`.cekernel-task.md`) correctly pre-cache issue data to avoid
  re-fetching within the context window

## Shell Environment

### Bash Tool Shell Selection

**Confidence: Stable**

Claude Code's Bash tool uses its own shell detection logic to determine which
shell to use — it does not simply invoke `$SHELL`. On macOS, the default shell
is zsh, so zsh is typically selected. This means:

- `BASH_SOURCE[0]` does not resolve correctly when scripts are `source`d in zsh
  (it is empty or wrong)
- Bash-specific syntax like `${!key:-}` (indirect expansion) is unavailable
- Arithmetic expressions with `(( ))` follow zsh semantics

The shell can be overridden via the `CLAUDE_CODE_SHELL` environment variable.

**Implications for cekernel**:
- Scripts that are `source`d (not executed with a shebang) must use the
  zsh-compatible `BASH_SOURCE` fallback: `${BASH_SOURCE[0]:-${(%):-%x}}`
- Scripts executed directly with `#!/usr/bin/env bash` are unaffected because
  bash is invoked explicitly by the shebang
- See CLAUDE.md "Known Pitfalls" for the canonical fallback pattern

**Reference**: #403 — BASH_SOURCE zsh 互換

## Plugin and Skill Variables

### `${CLAUDE_PLUGIN_ROOT}` Expansion Scope

**Confidence: Stable**

The `${CLAUDE_PLUGIN_ROOT}` variable is expanded only in:
- `hooks.json` — hook command definitions
- `.mcp.json` — MCP server configuration

It is **not** expanded in:
- `SKILL.md` files
- Agent markdown files (`agents/*.md`)
- `CLAUDE.md` or `.claude/rules/` files

**Implications for cekernel**:
- Skills and agents cannot use `${CLAUDE_PLUGIN_ROOT}` to locate plugin files
- Path resolution in skills must use alternative strategies (e.g., `Read` tool
  with relative paths from `${CLAUDE_SKILL_DIR}`, or `BASH_SOURCE`-based resolution)

### `${CLAUDE_SKILL_DIR}` Expansion Scope

**Confidence: Stable**

The `${CLAUDE_SKILL_DIR}` variable resolves to the directory containing the
current skill's `SKILL.md`. It is expanded **only** in bash injection blocks
(`` !`cmd` ``) within `SKILL.md`.

It is **not** expanded in:
- Regular markdown text in `SKILL.md`
- Agent markdown files
- Hook definitions or MCP configuration

**Implications for cekernel**:
- Skills that need to read reference files use bash injection to resolve paths:
  `` !`cat ${CLAUDE_SKILL_DIR}/../references/some-file.md` ``
- Agent markdown files cannot use `${CLAUDE_SKILL_DIR}` and must use other
  path resolution strategies

### `.claude/rules/` Auto-Loading

**Confidence: Evolving**

Files placed in `.claude/rules/` are automatically loaded into the agent's
context without requiring user approval. Symlinks are supported. These rules
function as additional project-level instructions alongside `CLAUDE.md`.

Current limitation: plugins cannot distribute files into `.claude/rules/` —
there is no plugin mechanism to install rules into the target project.

**Reference**: [anthropics/claude-code#14200](https://github.com/anthropics/claude-code/issues/14200)

**Implications for cekernel**:
- `.claude/rules/` is useful for project-specific agent instructions that
  should always be active
- cekernel cannot automatically install rules into target repositories via the
  plugin system — rules must be manually set up per project

## Tool Execution

### File System Access

**Confidence: Stable**

Claude Code agents have full read/write access to the filesystem within
their working directory. File operations are synchronous and atomic from
the agent's perspective.

**Implications for cekernel**:
- File-based IPC (signal files, state files, FIFOs) is a natural fit
- Atomic write patterns (temp + rename) work correctly

### Permission Model

**Confidence: Evolving**

Tool execution requires permission grants. These can be pre-configured via
`.claude/settings.json` (per-project) or granted interactively. The
`allowedTools` patterns support glob matching.

**Implications for cekernel**:
- Worker automation requires pre-configured permissions in the target
  repository's `.claude/settings.json`
- cekernel delegates permission configuration to the target repository
  (separation of authority)

## Concurrency and Multi-Session

### No Shared State Between Sessions

**Confidence: Stable**

Multiple Claude Code sessions (e.g., multiple terminal tabs) share no
in-process state. Each session is fully independent. Coordination must
occur through the filesystem or external services.

**Implications for cekernel**:
- The session IPC directory (`${CEKERNEL_VAR_DIR}/ipc/{SESSION_ID}`) is the
  correct coordination point. The base path defaults to `~/.local/var/cekernel`
  and is user-configurable via env profiles (e.g., `~/.config/cekernel/envs/default.env`)
- Workers in separate sessions correctly communicate via files and FIFOs
- There is no "shared memory" shortcut between agents

### Worker Process Backend

**Confidence: Stable**

cekernel spawns Worker sessions via a pluggable backend. Available backends
include terminal multiplexers (WezTerm, tmux) that send commands to terminal
panes, and a headless backend (ADR-0005) that spawns `claude` CLI processes
directly without a terminal.

**Implications for cekernel**:
- Worker process state (alive/dead) must be actively monitored
- Health detection (`health-check.sh`) is essential because there is
  no callback mechanism from the backend to cekernel
- The backend is swappable via `CEKERNEL_BACKEND` (ADR-0001, ADR-0005) —
  designs should not assume a specific backend
- The headless backend enables fully automated pipelines (CI, cron jobs)
  without terminal infrastructure
