# ADR-0016: cekernel v2 — Spawn Delegation to `claude --bg` Background Agents

## Status

Proposed

## Context

cekernel v1 forks `claude -p` directly in four paths:

| # | File | Purpose |
|---|------|---------|
| 1 | `scripts/scheduler/wrapper.sh` | cron/at scheduled execution |
| 2 | `scripts/ctl/spawn-orchestrator.sh` | Orchestrator as independent process |
| 3 | `scripts/shared/backends/headless.sh` | Worker (headless) |
| 4 | `scripts/shared/runner.sh` | Worker (wezterm/tmux pane) |

Claude Code has since standardized "spawn and supervise parallel independent
sessions" as a first-class primitive: `claude --bg`, `claude agents --json`,
`claude attach`, `claude stop`, `claude logs`, and an on-demand daemon
supervisor. cekernel duplicates this at the process-fork level (#534).

Additionally, the (currently paused) Programmatic/Interactive billing split
would classify `claude -p` paths as Programmatic (#526). Delegating spawn to
the standard session primitive is the strongest available hedge.

### Empirical findings (claude v2.1.201, verified 2026-07-06)

| Item | Finding |
|------|---------|
| `--bg` | Exists. Returns immediately, prints `backgrounded · <short-id>` to stdout. |
| Daemon | Auto-starts on demand (`Starting background service…`), exits when the last client disconnects. No service install required. `daemon status` / `daemon.log` available. |
| `--bg --exec '<cmd>'` | Works but is a **hidden flag** (absent from `--help`). Treat as unstable. |
| `--bg --session-id <uuid>` | **Not supported.** Warning: `--bg manages the session id; ignoring --session-id`. ID injection is impossible; capture is required instead. |
| Session ID capture | `claude agents --json` returns full `sessionId` UUIDs plus `cwd`, `kind` (`interactive`/`background`), `state`. Short ID = first 8 hex chars of the UUID. `--all` includes finished sessions; `--cwd <path>` filters. |
| States observed | `busy`, `done`, `stopped`, `blocked`. |
| `blocked` state | Session is waiting on a **permission dialog**. A misconfigured permission setup stalls a background worker silently — supervision must detect `blocked`. |
| Permissions | `--permission-mode acceptEdits` auto-approved a redirect write inside cwd. `--allowedTools` is **variadic** — it swallows a following positional prompt, so the prompt must precede the flag. |
| `--bg --agent <plugin:agent>` | Works. `--agent cekernel:probe` resolved the plugin agent; the session reported `agent_name = probe`. |
| Transcript | Written to the standard `~/.claude/projects/<mapped-cwd>/<full-uuid>.jsonl` path. `transcript-locator.sh` mapping remains valid with a captured UUID. |
| `claude logs <id>` | Raw TUI escape-sequence dump — **not machine-readable**. Transcripts remain the programmatic data source. |
| Lifecycle | A background session persists after its turn completes (`state: done`, still attachable). Explicit `claude stop <id>` is required to terminate it. |
| FIFO IPC PoC | A `--bg` session executed `echo poc-ok > <fifo>` via its Bash tool and the reader received it. FIFO IPC is agent-executed bash and is unaffected by the spawn mechanism. |

## Decision

cekernel v2 delegates **process spawn and supervision** to `claude --bg` and
the daemon. cekernel keeps only what the standard primitive does not provide:

1. Deterministic worktree naming (`issue/{N}-{slug}`)
2. FIFO IPC (completion notification to the Orchestrator)
3. Issue lock (duplicate-Worker prevention)
4. State / priority / checkpoint files (cross-session persistence)
5. OS scheduler integration (launchd/crontab/atd)
6. Issue number = PID identification and repo conventions

> cekernel becomes the **persistent + programmable layer** on top of the
> `claude agents` dashboard.

### Design inversions forced by findings

- **Session ID: inject → capture.** `--bg` ignores `--session-id`, so spawn
  scripts capture the daemon-assigned UUID from `claude agents --json`
  (matching on `cwd` + most recent `startedAt`, or the short ID printed at
  spawn) and record it where `*.claude-session-id` files live today.
  #528 (`--session-id` passthrough) is re-scoped accordingly.
- **Completion detection gains a second source.** FIFO IPC remains the
  primary push channel; `claude agents --json` `state` (`done`/`blocked`)
  becomes the poll/health channel, replacing PID-liveness heuristics.
  `blocked` MUST be surfaced by `watch.sh`/`orchctl ps` as a distinct state.
- **Lifecycle ownership.** Since `done` sessions linger, cleanup paths must
  call `claude stop <id>` in addition to existing worktree/IPC cleanup.

### Phased migration

| Phase | Content | Related |
|-------|---------|---------|
| 0 | `--bare` explicit spawn context (#532) | #532 |
| 1 | `headless.sh`: `claude -p` → `claude --bg --agent <worker>` + session-ID capture | #528 (re-scoped) |
| 2 | `spawn-orchestrator.sh` → `--bg` | |
| 3 | `wrapper.sh` (cron/at) → `--bg` with prompt (NOT `--exec`: hidden/unstable). Verify launchd/crontab can reach the on-demand daemon. | #526 |
| 4 | `orchctl ps` view layer → thin wrapper over `claude agents --json` | #527 / ADR-0015 |
| 5 | wezterm/tmux backends → spawn `--bg` then `claude attach <id>` in the pane | ADR-0001 amendment |

During migration, `CEKERNEL_SPAWN_MODE=legacy|delegated` (default `legacy`
until Phase 1–2 are validated, then `delegated`) switches the spawn path.

### Impact on open issues

- **#528**: re-scope from "pass `--session-id`" to "capture session ID from
  `--bg`"; the deterministic-transcript goal survives, the mechanism inverts.
- **#529** (`--fallback-model` passthrough): unaffected; flag passes through
  the same spawn wrapper.
- **#532** (`--bare`): composes with `--bg` (untested combination — verify in
  Phase 0/1).
- **#531**: Reviewer moves to a subagent path (separate ADR); Worker stays on
  the `--bg` path because it must survive the parent session.

## Consequences

### Positive

- Session IDs become authoritative at spawn time; `*.claude-session-id`
  persistence races disappear.
- `claude agents` becomes a free standard dashboard; `orchctl ps` shrinks to
  a view adapter (Parsimony).
- Daemon supervises background sessions; cekernel drops PID-file liveness
  heuristics where the daemon answers better.
- If the Programmatic billing split resumes, cekernel's spawn paths are
  session-based rather than `-p`-based.

### Negative / risks

- `--bg` surface is research-preview grade: `--exec` is hidden, flags and
  output format (`backgrounded · <id>`) may change. Mitigation: parse via
  `agents --json` only, pin minimum claude version, keep `legacy` mode.
- `blocked` (permission-wait) is a new silent-stall failure mode; requires
  explicit monitoring and correct `--allowedTools`/`--permission-mode`
  configuration per agent.
- Lingering `done` sessions leak if cleanup misses `claude stop`.
- Tests can no longer assert on `claude -p` argv; spawn tests need a mock
  `claude` CLI that emulates `--bg` stdout and `agents --json`. This feeds
  the v2 test-redesign ADR.

### Open questions (Phase 0/1 verification)

- `--bg --bare` combination behavior.
- launchd/crontab → on-demand daemon reachability (`/tmp/cc-daemon-501/...`
  socket path assumptions under cron environments).
- `agents --json` retention window for `--all` (how long finished sessions
  remain queryable).
