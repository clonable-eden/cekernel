# ADR-0001: Multi-terminal backend support

## Status

Accepted — Interface amended by ADR-0005 (8 functions → 4 external API, `terminal_*` → `backend_*`); execution model amended by Amendment 1 below (ADR-0016 Phase 5: attach-based visualization)

## Context

cekernel depends on WezTerm CLI (`wezterm cli`) for all programmatic terminal operations — spawning worker windows, sending commands, splitting panes, health checking, and cleanup. The dependency is already isolated behind `terminal-adapter.sh`, which exposes 8 functions (`terminal_available`, `terminal_spawn_window`, `terminal_run_command`, `terminal_split_pane`, `terminal_kill_pane`, `terminal_kill_window`, `terminal_pane_alive`, `terminal_resolve_workspace`).

Three callers consume this interface:
- `spawn-worker.sh` — creates worker windows with a 3-pane layout
- `health-check.sh` — checks pane liveness for zombie detection
- `cleanup-worktree.sh` — kills worker windows atomically

This creates two problems:

1. **Portability**: Users who don't use WezTerm cannot use cekernel. tmux users, remote SSH users, and CI environments are excluded.
2. **Headless operation**: Scheduled execution (#79 cron/at) requires running without any terminal, which is impossible under the current architecture.

## Decision

Introduce a **backend-switching mechanism** in `terminal-adapter.sh` driven by the `CEKERNEL_TERMINAL` environment variable, with three backends:

| Backend | `CEKERNEL_TERMINAL` | When to use |
|---------|---------------------|-------------|
| WezTerm | `wezterm` (default) | Local development with WezTerm |
| tmux | `tmux` | Remote/SSH, tmux users, Ghostty+tmux |
| Headless | `headless` | CI, cron/at scheduled runs, no-terminal environments |

Each backend implements the same 8-function interface. The dispatch is a single `case` statement at the top of `terminal-adapter.sh` that sources the appropriate backend file:

```
scripts/shared/
  terminal-adapter.sh           # dispatcher (reads CEKERNEL_TERMINAL)
  backends/
    wezterm.sh                  # current implementation, extracted
    tmux.sh                     # new
    headless.sh                 # new
```

### UNIX Philosophy Alignment

> Rule of Separation: "Separate policy from mechanism; separate interfaces from engines."

The decision of *which terminal to use* (policy) is separated from *how to operate a terminal* (mechanism). `terminal-adapter.sh` is the interface; `wezterm.sh`, `tmux.sh`, `headless.sh` are interchangeable engines. Callers (`spawn-worker.sh`, `health-check.sh`, `cleanup-worktree.sh`) remain untouched — they know nothing about which backend is active.

> Rule of Modularity: "Write simple parts connected by clean interfaces."

Each backend is a self-contained file implementing 8 functions. Adding a new backend means adding one file and one `case` branch. No existing code is modified. The interface boundary is already well-defined and tested.

> Rule of Diversity: "Distrust all claims for 'one true way.'"

WezTerm is excellent but it is one terminal among many. Locking cekernel to a single terminal contradicts the principle that tools should work within diverse environments. The env var approach lets each user choose the backend that fits their setup.

> Rule of Representation: "Fold knowledge into data so program logic can be stupid and robust."

The `CEKERNEL_TERMINAL` env var is the data that determines behavior. The dispatch logic is a trivial `case` statement — no conditional branching scattered across callers, no feature flags in business logic. Backend-specific knowledge lives in backend files, not in the code that uses them.

## Alternatives Considered

### Alternative: Abstraction via a wrapper binary

Write a standalone `cekernel-terminal` binary (in bash or another language) that accepts subcommands (`spawn`, `kill`, `alive`, etc.) and dispatches to the appropriate backend internally.

This approach was rejected based on:

> Rule of Parsimony: "Write a big program only when it is clear by demonstration that nothing else will do."

A separate binary adds a new executable, a new argument-parsing layer, and serialization overhead (function args → CLI args → parsing). The existing function-sourcing mechanism (`source terminal-adapter.sh`) already works. The problem is solved by reorganizing existing code, not by introducing a new program.

### Alternative: Auto-detect terminal at runtime

Instead of requiring `CEKERNEL_TERMINAL`, probe the environment: check for `wezterm cli`, then `tmux`, then fall back to headless.

This approach was rejected based on:

> Rule of Least Surprise: "In interface design, always do the least surprising thing."

Auto-detection creates ambiguity. A user with both WezTerm and tmux installed may be surprised when cekernel picks one over the other. A user in a tmux session inside WezTerm gets unpredictable behavior. Explicit configuration via env var is unsurprising and debuggable.

> Rule of Repair: "When you must fail, fail noisily and as soon as possible."

If a user sets `CEKERNEL_TERMINAL=tmux` but tmux is not installed, the failure is immediate and the cause is obvious. With auto-detection, the system silently falls back to a backend the user didn't expect, potentially producing confusing behavior far from the root cause.

### Alternative: Keep WezTerm-only, document it as a requirement

Do nothing. Require WezTerm for all cekernel usage.

This is the simplest option and respects the Rule of Simplicity. However, it blocks the entire cron/at scheduling feature (#79), which requires headless operation. It also excludes remote/SSH users and tmux-native workflows. The cost of the backend-switching mechanism is low (extract existing code + add 2 files), while the value unlocked (portability + headless) is high.

## Consequences

### Positive

- cekernel becomes terminal-agnostic — users choose their environment
- Headless mode unblocks #79 (cron/at scheduling) and CI-based execution
- Ghostty users can use cekernel via Ghostty+tmux combination
- Existing WezTerm users experience zero change (default backend)
- The 3 test suites (`test-terminal-adapter.sh`, `test-cleanup-pane.sh`, `test-health-check.sh`) already mock `wezterm` — the same pattern applies to each backend

### Negative

- Maintenance surface increases: 3 backend files instead of 1, each requiring testing
- `headless.sh` fundamentally changes the UX — no real-time pane visibility, only log files. Users must understand this trade-off
- tmux backend introduces a new external dependency (tmux must be installed)

### Trade-offs

**Simplicity vs. Diversity**: Adding backends increases code surface. However, the increase is bounded (each backend is ~50-80 lines implementing a fixed interface) and the existing separation in `terminal-adapter.sh` means no complexity leaks into callers. The trade-off is acceptable because the alternative — WezTerm lock-in — blocks meaningful future capabilities.

**Visibility vs. Portability** (headless mode specifically): The terminal pane layout (Claude Code + git log + terminal) provides valuable real-time visibility into Worker activity. Headless mode sacrifices this. The mitigation is file-based logging (`${CEKERNEL_IPC_DIR}/logs/worker-*.log`), which already exists. The Rule of Transparency is partially preserved through logs, though the experience is degraded compared to live panes.

## Amendment 1: Attach-based visualization (ADR-0016 Phase 5, 2026-07-07)

The original design ran the Worker **inside** the terminal pane: the pane
executed `claude -p` via a generated runner script, so the pane owned the
Worker process. ADR-0016 delegates spawn and supervision to `claude --bg`
background agent sessions on **all** backends; the terminal backends
(wezterm/tmux) become a pure **visualization layer**:

- **Spawn** goes through the shared session core
  (`scripts/shared/bg-session.sh`), identical to the headless backend.
  The pane runs `claude attach <session-id>` — an attach-only viewer.
  `runner.sh` (the `claude -p` runner generator) is removed.
- **Handles are unified**: `handle-{issue}.{type}` contains the opaque
  session token on every backend (ADR-0005 Amendment 1). The pane
  ID/target is a visualization detail recorded separately in
  `pane-{issue}.{type}`.

### Cleanup semantics change

Under the original design, pane death implied Worker death: liveness was
pane existence, and killing the window killed the Worker. Under
delegation this inverts:

| Event | Old semantics | New semantics |
|-------|---------------|---------------|
| Pane/window closed by user | Worker terminated | **Detach only** — the session keeps running under the daemon |
| Liveness check | pane exists? | `claude agents --json` state (`busy`/`blocked` = alive) |
| `backend_kill_worker` / `orchctl kill` | kill panes | `claude stop <token>` **and** close the window |
| Worktree cleanup | remove handle files | also `claude stop` (lingering `done` sessions leak otherwise) and remove `pane-*` files |

Consequences:

- Closing a pane is now a safe, non-destructive operation (Rule of Least
  Surprise for the `claude agents` generation: attach/detach is the
  standard UX). Re-attaching later via `claude attach <token>` works as
  long as the session lives.
- Supervision (`health-check.sh`, `watch.sh`, `orchctl`) must never infer
  Worker death from pane death. All liveness flows through the session
  state; `backend_worker_status` is part of the standard backend API.
- Terminating a Worker always requires `claude stop` — killing the
  window alone leaves the session running (and `done` sessions linger
  until stopped).

The **Visibility vs. Portability** trade-off above collapses: headless
and terminal backends now share one execution path, differing only in
whether an attach pane is opened. The visibility gap between them is
reduced to the viewer, not the lifecycle.
