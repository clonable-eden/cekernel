# Claude Code Platform Constraints

> Reference document for architectural decisions involving Claude Code.
> cekernel runs on Claude Code as its execution platform. Designs that ignore
> these constraints produce architectures that are correct in theory but
> unimplementable in practice.
>
> **Staleness warning**: Claude Code is actively evolving. Constraints listed
> here reflect the platform as of early 2025. When making architectural
> decisions, verify that constraints still hold — especially those marked
> with a confidence level below "Stable".

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
- The session IPC directory (`/usr/local/var/cekernel/ipc/{SESSION_ID}`) is the
  correct coordination point
- Workers in separate terminal panes correctly communicate via files and FIFOs
- There is no "shared memory" shortcut between agents

### Terminal Backend Dependency

**Confidence: Stable**

cekernel spawns Worker sessions by sending commands to terminal panes.
The terminal multiplexer (WezTerm, tmux, etc.) is an external dependency
that cekernel does not control.

**Implications for cekernel**:
- Terminal pane state (alive/dead) must be actively monitored
- Pane death detection (`health-check.sh`) is essential because there is
  no callback mechanism from the terminal to cekernel
- The terminal backend is swappable (ADR-0001, ADR-0005) — designs should
  not assume a specific terminal
