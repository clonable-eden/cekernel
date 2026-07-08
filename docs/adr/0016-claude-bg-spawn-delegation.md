# ADR-0016: cekernel v2 — Spawn Delegation to `claude --bg` Background Agents

## Status

Accepted

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

> The living, staleness-managed copy of these observations is
> [`docs/claude-code-constraints.md`](../claude-code-constraints.md#background-agent-sessions---bg--on-demand-daemon)
> (**Confidence: Evolving**). The table below is preserved as the decision
> record — what was true when this ADR was written.

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
  scripts capture the daemon-assigned UUID and record it where
  `*.claude-session-id` files live today. Capture order is normative:
  1. **Primary**: extract the short ID from the spawn stdout line
     (`backgrounded · <short-id>`), then prefix-match it against
     `sessionId` in `claude agents --json`. Deterministic even with
     concurrent spawns.
  2. **Fallback** (stdout parse fails): match on `kind == "background"` +
     `cwd` + most recent `startedAt`. The `kind` filter is mandatory —
     the Orchestrator shares the repo-root cwd with interactive sessions.

  #528 (`--session-id` passthrough) is re-scoped accordingly.
- **Completion-detection hierarchy (ADR-0007 relation).** The ADR-0007
  dual path is unchanged: FIFO stays the primary push channel and the
  Worker-authored state file stays the detail/fallback source. What
  `agents --json` replaces is exactly one thing — **PID-liveness
  heuristics** (`kill -0`, PID files) as the supervisor's health check —
  and it adds the `blocked` signal, which no existing source can see.
  `blocked` MUST be surfaced by `watch.sh`/`orchctl ps` as a distinct
  state. No fourth source may be added without amending this ADR.
- **Lifecycle ownership.** Since `done` sessions linger, cleanup paths must
  call `claude stop <id>` in addition to existing worktree/IPC cleanup.
- **Backend contract (ADR-0005) changes shape.** The backend API's handle
  is currently a numeric PID, with `backend_get_pid`, `kill -0` liveness,
  and `kill -- -PID` termination built on it. Under delegation the handle
  becomes an **opaque token** (session ID); liveness maps to `agents
  --json` state and termination to `claude stop`. Renaming/retyping the
  ADR-0005 interface is an explicit Phase 1 deliverable, not an incidental
  edit.

### Phased migration

| Phase | Content | Related |
|-------|---------|---------|
| 0 | `--bare` explicit spawn context (#532) | #532 |
| 1 | `headless.sh`: `claude -p` → `claude --bg --agent <worker>` + session-ID capture | #528 (re-scoped) |
| 2 | `spawn-orchestrator.sh` → `--bg` | |
| 3 | `wrapper.sh` (cron/at) → `--bg` with prompt (NOT `--exec`: hidden/unstable). Verify launchd/crontab can reach the on-demand daemon. **Registry semantics change**: `--bg` returns immediately, so the exit-code-based success/error/duration recording is impossible. `wrapper.sh` polls `agents --json` to a terminal state (`done` → `success`; `blocked`/timeout → `error`; duration = poll window). Note the fidelity loss: `done` means the session finished, not that the job inside it succeeded — job-level outcomes stay in transcripts and notifications. | #526 |
| 4 | `orchctl ps` view layer → thin wrapper over `claude agents --json` | #527 / ADR-0015 |
| 5 | wezterm/tmux backends → spawn `--bg` then `claude attach <id>` in the pane | ADR-0001 amendment |

**2.0.0 is a breaking release — there is no runtime compatibility mode.**
The `claude -p` spawn paths are removed outright; no
`CEKERNEL_SPAWN_MODE`-style switch ships. The **1.x line is the legacy
mode**: users who need `-p` spawning stay on `cekernel-v1.9.x`. This is
exactly what the major version exists for, and it removes an entire class
of complexity (4 spawn paths × 2 modes, a legacy test lane, a retirement
process for the switch).

The hedge against `--bg`'s research-preview instability is **not** a
runtime fallback but the release gate below: development happens on the
`2.0-dev` branch, validated by self-hosting; if the platform primitive
proves unfit, 2.0.0 does not ship (or a scope reduction — e.g. `wrapper.sh`
keeping `-p` — is recorded as an amendment here).

**Release gate for 2.0.0**: the Open questions below — above all
daemon-lifetime vs. Worker survival — are verified with positive results.
Verification failures block the release, not soften it into dual-mode.

### Impact on open issues

- **#528**: re-scope from "pass `--session-id`" to "capture session ID from
  `--bg`"; the deterministic-transcript goal survives, the mechanism inverts.
- **#529** (`--fallback-model` passthrough): unaffected; flag passes through
  the same spawn wrapper.
- **#532** (`--bare`): composes with `--bg` (untested combination — verify in
  Phase 0/1).
- **#531**: Reviewer moves to a subagent path (separate ADR); Worker stays on
  the `--bg` path because it must survive the parent session.

## Amendment 1: Conditional `--bare` (2026-07-07)

Phase 0/1 shipped `--bare` unconditionally on every spawn path. In practice
this **locks out subscription (OAuth) operators**: `--bare` never reads
OAuth/keychain, so spawns hard-require `ANTHROPIC_API_KEY` or an
`apiKeyHelper` settings file — turning every Worker into pay-as-you-go API
usage for operators who authenticate via a Claude subscription (the
primary cekernel audience). This was an over-alignment with the upstream
"`--bare` will become the default for `-p`" signal: v2's execution path is
`--bg`, not `-p`, and OAuth works fine there.

**Decision** (user-approved 2026-07-07): `--bare` becomes **conditional on
auth availability**:

- A bare-compatible auth path exists (`ANTHROPIC_API_KEY` or
  `CEKERNEL_CLAUDE_SETTINGS` with `apiKeyHelper`) → spawn with
  `--bare` + explicit context injection (current behavior).
- Otherwise → spawn WITHOUT `--bare` (normal `--bg`, OAuth/keychain auth),
  emitting a one-line notice that bare mode is disabled for this spawn.
- Scheduled paths (cron/at via `wrapper.sh`) keep the **hard preflight
  failure**: they run unattended, where silent OAuth expiry is worse than
  a noisy refusal, and their setup docs already require
  `CEKERNEL_CLAUDE_SETTINGS`.

This is auth-environment adaptation, not a legacy/delegated runtime mode —
the spawn mechanism (`--bg`) is identical on both branches.

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
  output format (`backgrounded · <id>`) may change. Mitigation: all
  **structured** data is read from `agents --json` only; the human-oriented
  spawn line is parsed solely to extract the short-ID token, and the
  `kind`+`cwd`+`startedAt` fallback covers a format change there. Pin the
  minimum claude version. There is no runtime fallback — the 1.x release
  line covers users the preview instability would strand, and the 2.0.0
  release gate covers cekernel itself.
- `blocked` (permission-wait) is a new silent-stall failure mode; requires
  explicit monitoring and correct `--allowedTools`/`--permission-mode`
  configuration per agent.
- Lingering `done` sessions leak if cleanup misses `claude stop`.
- Tests can no longer assert on `claude -p` argv; spawn tests need a mock
  `claude` CLI that emulates `--bg` stdout and `agents --json`. This feeds
  the v2 test-redesign ADR.

### Open questions (Phase 0/1 verification)

- **Daemon lifetime vs. Worker survival**: the daemon "exits when the last
  client disconnects" — does a running background session count as a
  client, and can a long-running Worker be orphaned or killed by daemon
  exit? (`claude daemon stop --keep-workers` implies detached sessions can
  survive a stop, but the default interaction is unverified.) This is
  load-bearing for the Worker-stays-independent decision (#531) and MUST
  be verified in Phase 1 — it is the primary 2.0.0 release gate.
- `--bg --bare` combination behavior.
- launchd/crontab → on-demand daemon reachability (`/tmp/cc-daemon-501/...`
  socket path assumptions under cron environments).
- `agents --json` retention window for `--all` (how long finished sessions
  remain queryable).
