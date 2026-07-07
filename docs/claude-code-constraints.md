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

Additionally (observed 2026-07-07, claude v2.1.201): **the harness may
auto-detach a long-running foreground Bash call into a background task**
even when the agent intended a blocking call. In `claude -p` execution this
is fatal in combination with turn-end process exit: the agent believes it
will be re-invoked on completion, ends its turn, and the process dies with
its watchers (#558). Setting `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in
the spawned process's environment keeps Bash calls truly in the foreground.

**Implications for cekernel**:
- Background watchers can improve signal detection latency (seconds vs minutes)
  but must not replace phase-boundary checks as the reliable baseline
- Design with the assumption that background notifications may be delayed or missed
- Orchestrators keep `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` under
  `--bg` (ADR-0016 Phase 2; spawn-orchestrator.sh sets it): turn end no
  longer kills the process — the session lingers in `done` — but whether
  a background-task completion notification re-invokes a `done` session
  is **unverified**. Without re-invocation, an auto-detached wait becomes
  a silent stall instead of a crash (Rule of Repair: prefer the known
  failure mode). Re-evaluate once re-invoke behavior is verified.
- Under `--bg`, sessions inherit the **daemon's** environment, not the
  spawning caller's (verified 2026-07-07, v2.1.202: a Worker session's
  process env — including PATH — was byte-identical to the daemon's;
  the `.cekernel-env` values exported in the caller subshell did not
  reach the session directly). Caller env reaches sessions only when
  that spawn auto-starts the daemon. In practice a cekernel run's first
  spawn (`spawn-orchestrator.sh`) auto-starts the daemon with the run's
  values, so `CEKERNEL_*` and PATH are present in all of the run's
  sessions — but a daemon left over from a previous run serves **stale**
  env (#589). The prompt remains the authoritative channel: agent
  definitions instruct a startup check against prompt values. Treat
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` as defense-in-depth, not a
  guarantee — the agent-level "foreground watch" instructions in
  orchestrator.md remain the reliable baseline

**References**:
[anthropics/claude-code#21048](https://github.com/anthropics/claude-code/issues/21048),
[anthropics/claude-code#20525](https://github.com/anthropics/claude-code/issues/20525)

## Agent Architecture

### Single-Threaded Agent

**Confidence: Stable**

Each Claude Code session runs a single agent. There is no built-in mechanism
for an agent to spawn *peer* agents within the same session. Multi-agent
coordination requires external orchestration (separate terminal sessions,
separate processes). (This concerns *peer* agents sharing one context;
**subagents**, which each get their own context window, are a distinct
mechanism and *are* supported — see [Subagent Nesting](#subagent-nesting)
below. cekernel uses both: Workers are peer processes, the Reviewer is a
subagent.)

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

### Subagent Nesting

**Confidence: Evolving** (officially supported since v2.1.172)

Nested subagents are officially supported: a subagent can spawn its own
subagents, with a **fixed depth limit of 5**. The historical constraint
("nesting depth ≥ 2 is unreliable" — context exhaustion, communication
failures) applied to versions before v2.1.172 and is obsolete.

Additionally, since the Orchestrator became an independent process
(`claude -p` / `--bg`, ADR-0016), it is a session **main thread** — a
subagent it spawns via the Agent tool is only depth 1.

Related observations (claude v2.1.201, 2026-07-06):
- Agent frontmatter supports `isolation: worktree`: the subagent receives a
  git worktree under `.claude/worktrees/agent-<id>`, branched from the
  **default branch** by default (`worktree.baseRef: head` selects the
  parent's `HEAD` instead)
- On agent-worktree creation, Claude Code appends `**/.claude/worktrees/`
  (and other runtime paths) to the repository's `.git/info/exclude` under a
  `# claude-code-runtime` marker — the main tree's `git status` stays clean
  without any project `.gitignore` entry
- Worktree auto-removal aborts only when `git status --porcelain` reports a
  **dirty working tree**. Fetching and moving HEAD (e.g., a detached PR
  checkout) does not count as a change, so a read-only subagent's worktree
  is removed automatically
- Relative symlinks (e.g., `.claude/rules/*.md` → `../../docs/*.md`) resolve
  correctly inside a full worktree checkout
- A main-thread agent can restrict spawnable subagent types with the
  `Agent(agent_type)` allowlist syntax in its `tools` frontmatter

**Plugin-mode note (verified 2026-07-07, #600)**: plugin-provided agents
**can** be spawned as Agent-tool subagents — a `--plugin-dir` session
successfully spawned `cekernel:probe` as a subagent. The catch is the
parent agent's `Agent(...)` allowlist: it must permit the name actually
used, which is plugin-namespaced (`cekernel:reviewer`) in plugin mode but
bare (`reviewer`) in local mode. A grant of `Agent(reviewer)` silently
blocks `cekernel:reviewer` (the tool reports "not found" with an empty
available list) — this is how #600 broke the Reviewer under plugin
distribution. Plugin-namespaced allowlist entries (`Agent(cekernel:reviewer)`)
are **undocumented**; for an agent that must spawn a sibling in both modes,
use unrestricted `Agent` (no parentheses).

**Implications for cekernel**:
- The Reviewer runs as an Orchestrator subagent with `isolation: worktree`
  and a structured return contract (ADR-0012 Amendment 2), replacing the
  spawn + FIFO pattern
- Independent processes with FIFO IPC remain the right tool where
  **cross-session persistence** is required (Workers) — subagents live and
  die with their parent session

### Dynamic Workflows (`/workflows`)

**Confidence: Evolving** (research preview; observed on claude v2.1.201, 2026-07-06)

The `Workflow` tool runs a JavaScript script that deterministically
orchestrates subagents via `agent()`, `parallel()`, `pipeline()`, and
`phase()`.

Observed characteristics:
- Intermediate results live in script variables and a run journal, not in
  the calling session's context window
- Concurrency cap `min(16, cpu cores - 2)` per workflow; 1000 agents per
  run lifetime; 4096 items per `pipeline()`/`parallel()` call
- Workflow agents are **subagents of the running session**: per-call
  `isolation: 'worktree'` is available, they share the session's MCP/tool
  surface, and can return schema-validated structured output
- Resume (`resumeFromRunId`) replays cached `agent()` results —
  **same-session only**; `Date.now()`/`Math.random()` are banned inside
  scripts to keep runs replayable
- Invocation is gated on **explicit user opt-in** (user wording, ultracode
  mode, or a skill whose instructions direct the call)

Unverified (check before relying on them):
- Whether an **agent definition's** system-prompt instruction satisfies the
  opt-in gate in a non-interactive session (`claude --bg --agent ...`),
  where no user utterance exists
- Whether the Workflow tool is present on a **subagent's** tool surface
  (e.g. a Reviewer subagent at depth 1 launching workflow agents at
  depth 2), and whether an agent's `tools:` frontmatter must list it

**Implications for cekernel**:
- Division of labor is governed by ADR-0015: cekernel persists across
  sessions, `/workflows` fans out within one
- Any cekernel agent intending to use a workflow must resolve the
  unverified items above first (ADR-0015 Open questions)

### Background Agent Sessions (`--bg` / on-demand daemon)

**Confidence: Evolving** (research preview; observed on claude v2.1.201,
2026-07-06; matrix re-verified on v2.1.202, 2026-07-07)

`claude --bg` starts a session as a background agent and returns
immediately; sessions are supervised by an on-demand daemon and managed
via `claude agents` / `attach` / `stop` / `logs`.

Observed characteristics:
- Daemon auto-starts on demand (`Starting background service…`) and exits
  when the last client disconnects; no service install required
- `--bg` prints `backgrounded · <short-id>` to stdout; the short ID is the
  first 8 hex chars of the session UUID. Full `sessionId`, `cwd`, `kind`
  (`interactive`/`background`), and `state` come from `claude agents
  --json` (`--all` includes finished sessions, `--cwd` filters)
- `--bg` **ignores `--session-id`** (warning: `--bg manages the session
  id`) — external ID injection is impossible; capture is required
- Observed states: `busy`, `done`, `stopped`, `blocked`. `blocked` means
  the session is waiting on a **permission dialog** — a misconfigured
  permission setup stalls a background session silently
- A background session persists after its turn completes (`state: done`,
  still attachable); explicit `claude stop <id>` terminates it
- `claude logs <id>` is a raw TUI escape-sequence dump — not
  machine-readable; transcripts under `~/.claude/projects/` (full-UUID
  filenames, standard cwd mapping) remain the programmatic data source
- `--bg --agent <plugin:agent>` resolves plugin agents
- `--bg --exec '<cmd>'` works but is a **hidden flag** (absent from
  `--help`) — treat as unstable
- `--allowedTools <tools...>` is variadic and swallows a following
  positional prompt; the prompt must precede the flag

Verified 2026-07-07 (31-minute busy probe, session `cada4872`):
- **Daemon lifetime is tied to running sessions, not CLI clients.** The
  daemon (single PID) stayed alive for the full 31-minute busy window
  after the spawning client exited, and shut down only after the session
  completed. Long-running Workers are NOT orphaned by daemon exit.
  Lingering `done` sessions do not keep the daemon alive.
- **Minimal-environment spawn works**: `env -i HOME=... PATH=...` (cron
  approximation) successfully auto-started the daemon and spawned a
  session. Real launchd/crontab verification remains for Phase 3.
- **Retention**: `agents --json --all` still listed sessions ~3 weeks old.

Verified 2026-07-07 (Phase 1 probe, #546, session `971e554a`):
- **`--bg --bare` with a prompt composes without warnings** (unlike the
  hidden `--exec` path, which emits `--exec ignores --bare`). The session
  spawns and appears in `agents --json` normally.
- `agents --json` records carry **more fields than the normative five**:
  `pid` (daemon-side session process), `id` (short ID), `name` (prompt
  excerpt), `status` — do not rely on an exclusive field set. `startedAt`
  is **epoch milliseconds** (numeric), not an ISO string.
- The reported `cwd` is **realpath'd** (`/tmp` → `/private/tmp` on macOS)
  — cwd-based matching must normalize with `pwd -P` first.
- `claude stop <short-id>` accepts the short ID as the stop token.

Verified 2026-07-07 (#581 field split, #591 terminal conflation, #593
roster observation; claude v2.1.202):
- **Live and terminal sessions report their state in different fields**:
  liveness lives in `status`, terminality in `state`. Reading `.state`
  alone evaluates every live session as `working` and mis-reports it
  dead (#581: watch.sh crash-flagged all spawned Workers). Reading
  `(.status // .state)` breaks the other direction: `done` sessions
  carry `status: "idle"`, so the expression returns "idle" and terminal
  detection never fires (#591).
- **Observed (status, state) matrix** (ADR-0018 — this table is the
  contract; it is mirrored in `scripts/shared/claude-bg.sh` and
  `tests/helpers/mock-claude.bash`):

  | `status` | `state` | Verdict |
  |----------|---------|---------|
  | `busy` | `working` | alive |
  | `busy` | (absent) | alive |
  | (absent) | `busy` | alive (pre-split legacy shape) |
  | `blocked` | `working` | blocked (v2.1.201 shape) |
  | `idle` | `blocked` | blocked (v2.1.202 shape) |
  | (absent) | `blocked` | blocked (pre-split legacy shape) |
  | `idle` | `done` | terminal (`done`) |
  | (absent) | `done` | terminal (`done`; `--all`, daemon-restart rows) |
  | `idle` | `stopped` | terminal (`stopped`) |
  | (absent) | `stopped` | terminal (`stopped`; `--all`, daemon-restart rows) |
  | — session absent — | | not-listed |
  | any pair not above | | unknown-value |

  Real roster tally (2026-07-07, v2.1.202): `busy/working`,
  `busy/(absent)` (interactive), `idle/blocked`, `idle/done`,
  `(absent)/done`, `(absent)/stopped`. Note `blocked` appeared in
  `state` with `status: "idle"` — NOT in `status` as ADR-0018
  originally predicted from v2.1.201.
- **`agents --json` does not resurrect the daemon** (isolated-HOME
  probe, v2.1.202, #593): with no daemon running, `claude agents
  --json` (and `--all`) returns `[]` with exit 0, starts no `claude
  daemon run` process, and writes no daemon.json. Predicates are
  side-effect-free observers. Implication: a stopped daemon is
  indistinguishable from an empty roster — it surfaces as `not-listed`,
  NOT as `query-failed`.
- **The daemon's inherited environment is unspecified** (#589, ADR-0018
  Decision 3): the on-demand daemon keeps the env of whichever client
  auto-started it, and sessions inherit the DAEMON's env, not their
  spawner's (verified 2026-07-07, v2.1.202). No cekernel code may rely
  on it. Session env is guaranteed by the spawner: Workers source the
  worktree's `.cekernel-env` per Bash call (normative), Orchestrators
  receive explicit exports from `spawn-orchestrator.sh` plus prompt-
  embedded values.

**Implications for cekernel**:
- ADR-0016 delegates spawn/supervision to `--bg`; session IDs are captured
  (never injected); `blocked` must be surfaced by supervision; cleanup
  must `claude stop` lingering `done` sessions
- `scripts/shared/claude-bg.sh` is the SOLE owner of this surface
  (ADR-0018): all `--bg` invocation, spawn-line parsing, `agents --json`
  parsing, and `claude stop` live there; consumers use its verdict
  predicates and keep their own degradation policies. A direct parse
  anywhere else is a review-blocking violation (CLAUDE.md § Review)
- `tests/helpers/mock-claude.bash` emits the matrix shapes (STALENESS
  COUPLING: update the mock and claude-bg.sh in the same PR as this
  section)

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

## Hooks

### Stop / SubagentStop Decision Control

**Confidence: Evolving** (additionalContext released in v2.1.166, 2026-06-06;
verified against the official hooks documentation 2026-07-07)

`Stop` and `SubagentStop` hooks can keep the conversation going in two ways:

- `decision: "block"` + `reason` — rendered as a **hook error**; `reason`
  becomes the next instruction
- `hookSpecificOutput.additionalContext` — **non-error feedback**; the
  transcript labels it hook feedback and no error notification is shown

Both paths share the same loop protections: the hook input carries
`stop_hook_active: true` when the session is already continuing due to a stop
hook, and Claude Code force-ends the turn after **8 consecutive
continuations**.

Additional verified facts:

- Hook output strings (`additionalContext`, `systemMessage`, plain stdout)
  are capped at **10,000 characters**; overflow is written to a file and
  replaced with a preview plus the file path
- When several hooks return `additionalContext` for the same event, **all**
  values are delivered
- `Stop`/`SubagentStop` input includes `last_assistant_message` (no transcript
  parsing needed) and, since v2.1.145, `background_tasks` / `session_crons`
  arrays that distinguish "done" from "paused awaiting background work"
- `SubagentStop` matches on agent type; plugin-shipped agents use the
  plugin-scoped identifier (matcher `^cekernel:reviewer$`, anchored because
  the colon triggers regex matching)
- `SubagentStart` can inject `additionalContext` into a subagent **at start**
  (no blocking or decision control)
- Stop hooks do not fire on user interrupts; API-error turn ends fire
  `StopFailure` instead (logging only, no decision control)

**Implications for cekernel**:
- `scripts/hooks/worker-stop-guard.sh` (ADR-0019) returns `additionalContext`
  to keep a Worker session running until `notify-complete.sh` records
  TERMINATED — a turn-boundary guard against Workers dying before their
  completion notification (#558 family)
- `Stop` fires for main-thread sessions (Workers and Orchestrators under
  `--bg`); `SubagentStop` fires for subagents (Reviewer)
- The 8-continuation cap means a stop-hook loop is self-limiting: a Worker
  that cannot complete is eventually released

### Hook Loading Under `--bare`

**Confidence: Evolving**

`--bare` skips auto-discovery of hooks (along with skills, plugins, MCP
servers, auto memory, and CLAUDE.md): hooks configured in the target
repository's `.claude/settings.json` or the user's `~/.claude` never run in a
bare-mode session. Only explicitly passed flags take effect — the documented
injection paths are `--settings <file>` and `--plugin-dir <path>` (a plugin's
`hooks/hooks.json` merges when the plugin is enabled).

**Verified (2026-07-07, controlled experiment)**: `--plugin-dir <cekernel-root>`
enables the cekernel plugin's `hooks/hooks.json` auto-discovery and resolves
`${CLAUDE_PLUGIN_ROOT}` inside hook commands. A session started in a fake Worker
worktree *with* `--plugin-dir` received the Stop guard's `additionalContext`
and continued (`num_turns=13`); the identical session *without* it stopped at
`num_turns=1`. Because every cekernel spawn branch passes `--plugin-dir`
(`bare-mode.sh`, ADR-0016 Amendment 1), plugin hooks fire in spawned Worker
sessions under **both** local self-hosting and plugin-installed usage — the
enabling signal is the spawn-time flag, not the parent's plugin/local namespace.
See ADR-0019 Consequences.

**Implications for cekernel**:
- cekernel-origin lifecycle hooks must ship in the plugin's `hooks/hooks.json`
  — cekernel passes `--plugin-dir <cekernel-root>` on every spawn branch
  (bare and non-bare, ADR-0016 Amendment 1), so plugin hooks reach Worker
  sessions either way. Note: plugin-hook loading under `--bare --plugin-dir`
  is documented but not yet live-verified in a cekernel spawn (ADR-0018
  Consequences)
- Target-repo hooks are unavailable in bare-mode Workers by design; anything
  the Worker lifecycle depends on must not live in target-repo hook
  configuration

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

**No query API**: there is no claude CLI command to ask "would this tool be
permitted?" — only `--permission-mode` and the `--dangerously-skip-*`
bypass flags exist (verified v2.1.201). Code that needs to know permission
outcomes must either try the action and observe, or coarsely inspect
`settings.json` itself; it cannot delegate resolution to the platform.

**Three-layer permission structure** (observed across 24 self-hosted PRs,
2026-07-07): a headless Worker's tool call passes through three gates:

1. **settings.json allowlist** — `permissions.allow` in the target repo's
   `.claude/settings.json`. Depends on the *target repo* having one
   (`#543` passed normal Bash/Edit/Write/Read via `allow:[...]`).
2. **Safety classifier** — a classifier still rejects dangerous patterns
   even when layer 1 allows the tool broadly. Observed: `#543` had `bats`
   (external-repo code) rejected as "[Code from External]"; `#593` had
   `rm -rf /tmp/...` "denied". **The mechanism is unconfirmed** — whether
   it is inherited from the spawning supervisor's auto mode, or is a
   classifier intrinsic to headless sessions, is not yet distinguished
   (an earlier spawn mix-up, #545, warns against asserting inheritance).
3. **blocked / denied** — when layers 1–2 are not satisfied, the session
   either stalls silently on a permission dialog (`blocked`) or the tool
   returns a denial the agent must handle.

**Implications for cekernel**:
- Worker automation requires pre-configured permissions in the target
  repository's `.claude/settings.json`. **A target repo without a Worker
  allowlist strands the Worker at layer 3 (silent `blocked`)** — the
  self-hosting case hides this because cekernel's own settings happen to
  suit. cekernel should surface the gap early, not resolve permissions.
- cekernel delegates permission configuration to the target repository
  (separation of authority) — and cannot reimplement the resolution engine
  (no query API). See ADR-0012 Amendment 4.
- Layer 2 is outside cekernel's control; its mechanism is Evolving and
  should be re-verified (supervisor-auto-mode vs headless-intrinsic).

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
