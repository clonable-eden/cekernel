# ADR-0005: Headless Backend and Interface Redesign

## Status

Accepted — Amends the interface defined in ADR-0001.
Amended by [Amendment 1](#amendment-1-2026-07-07-opaque-session-token-handles-under-adr-0016-delegation) (opaque session-token handles, ADR-0016 Phase 1).

## Context

ADR-0001 established a backend-dispatch architecture for `terminal-adapter.sh`, enabling WezTerm and tmux backends via `CEKERNEL_TERMINAL` env var. The headless backend — launching `claude --agent` as a background process without any terminal multiplexer — is the final planned backend.

However, the current 8-function interface was designed around terminal multiplexer semantics (windows, panes, split). Adding a headless backend forces several functions to become no-ops, revealing that the abstraction is terminal-centric rather than worker-lifecycle-centric.

An IPC channel audit confirmed that **zero** information flows through terminal stdout/stderr. All Orchestrator-Worker communication uses file-based IPC (FIFO, state files, signal files, task files, checkpoint files, priority files). This means headless mode is viable with no changes to the IPC layer.

### Current Interface (8 functions)

```
terminal_available
terminal_resolve_workspace
terminal_spawn_window          ← internal only
terminal_run_command           ← internal only
terminal_split_pane            ← internal only
terminal_spawn_worker_layout
terminal_kill_pane
terminal_kill_window
terminal_pane_alive
```

### Current Callers

| Caller | Functions Used |
|--------|---------------|
| `spawn-worker.sh` | `resolve_workspace`, `spawn_worker_layout`, `kill_pane` (rollback) |
| `health-check.sh` | `available`, `pane_alive` |
| `cleanup-worktree.sh` | `available`, `kill_window` |

`spawn_window`, `run_command`, `split_pane` are only called internally by `spawn_worker_layout` implementations.

## Decision

### 1. Rename and reduce the external API to 4 functions

```
terminal-adapter.sh  →  backend-adapter.sh
terminal-backends/   →  backends/            (already this name)
CEKERNEL_TERMINAL    →  CEKERNEL_BACKEND     (env var rename)
```

The environment variable `CEKERNEL_TERMINAL` is renamed to `CEKERNEL_BACKEND` to match the file and function renames. Since headless mode has no terminal, keeping `CEKERNEL_TERMINAL=headless` would be contradictory. There is no backward compatibility concern — the env var is set per-session, not persisted in configuration files.

External API:

| Function | Purpose | WezTerm/tmux | Headless |
|----------|---------|-------------|----------|
| `backend_available` | Check if backend is usable | `command -v wezterm/tmux` | Always true |
| `backend_spawn_worker` | Start a Worker process | Spawn window + layout + command | `claude --agent &` |
| `backend_worker_alive` | Check if Worker is alive | Pane alive check | `kill -0 $PID` |
| `backend_kill_worker` | Terminate a Worker | Kill window (all panes) | `kill $PID` |

Removed from external API:

| Old Function | Disposition |
|-------------|------------|
| `terminal_resolve_workspace` | Absorbed into `backend_spawn_worker` (backend decides internally) |
| `terminal_spawn_window` | Private: `_backend_spawn_window` (WezTerm/tmux internal) |
| `terminal_run_command` | Private: `_backend_run_command` (WezTerm/tmux internal) |
| `terminal_split_pane` | Private: `_backend_split_pane` (WezTerm/tmux internal) |
| `terminal_kill_pane` | Merged into `backend_kill_worker` |
| `terminal_kill_window` | Merged into `backend_kill_worker` |

### 2. Encapsulate handle files inside the backend

Currently, callers directly read/write `pane-{issue}` files:

```bash
# spawn-worker.sh (current)
echo "$MAIN_PANE" > "${CEKERNEL_IPC_DIR}/pane-${ISSUE_NUMBER}"

# health-check.sh (current)
pane_id=$(cat "${CEKERNEL_IPC_DIR}/pane-${ISSUE_NUMBER}")
terminal_pane_alive "$pane_id"
```

Instead, each backend manages its own handle internally. Callers pass only the issue number:

```bash
# spawn-worker.sh (proposed)
backend_spawn_worker "$ISSUE_NUMBER" "$WORKTREE" "$PROMPT"
# internally saves pane ID or PID to handle file

# health-check.sh (proposed)
backend_worker_alive "$ISSUE_NUMBER"
# internally reads handle file and checks liveness
```

Handle file format is a backend implementation detail:
- WezTerm: pane ID (numeric)
- tmux: pane target (`session:window.pane`)
- Headless: PID (numeric)

### 3. Implement `backends/headless.sh`

```bash
backend_available() { return 0; }

backend_spawn_worker() {
  local issue="$1" worktree="$2" prompt="$3"
  # Use setsid to create a new process group for clean termination
  setsid bash -c "
    cd '$worktree' && \
    CEKERNEL_SESSION_ID='$CEKERNEL_SESSION_ID' \
    claude --agent cekernel:worker '$prompt' \
    > '${CEKERNEL_IPC_DIR}/logs/worker-${issue}.stdout.log' 2>&1
  " &
  echo $! > "${CEKERNEL_IPC_DIR}/handle-${issue}"
}

backend_worker_alive() {
  local pid; pid=$(cat "${CEKERNEL_IPC_DIR}/handle-${1}")
  kill -0 "$pid" 2>/dev/null
}

backend_kill_worker() {
  local pid; pid=$(cat "${CEKERNEL_IPC_DIR}/handle-${1}")
  # Kill the entire process group (claude + child processes)
  kill -- -"$pid" 2>/dev/null
}
```

SESSION_ID propagation becomes a direct environment variable pass — simpler than WezTerm OSC or tmux send-keys.

Note on `backend_spawn_worker` argument change: the current `terminal_spawn_worker_layout` takes `(cwd, workspace, json_payload)`. The new signature takes `(issue, worktree, prompt)`, dropping workspace (absorbed internally) and changing the payload from JSON to a prompt string. WezTerm's backend implementation must construct the JSON payload internally, as the WezTerm Lua handler still expects JSON.

#### Process group management

Terminal backends (WezTerm/tmux) handle child process cleanup implicitly — killing a pane or window terminates all processes within it. Headless mode lacks this containment. `claude --agent` spawns child processes (git, npm, test runners, etc.) that would become orphans if only the parent PID is killed.

The solution is `setsid` + process group kill:
- `setsid` creates a new session and process group for the Worker
- `kill -- -$PID` sends the signal to the entire process group
- This mirrors the terminal backend's behavior: killing a pane terminates all processes within it

#### Impact on ADR-0003 (Signal mechanism)

ADR-0003 defines `KILL` as "Orchestrator kills terminal pane (existing mechanism via `cleanup-worktree.sh`)". With headless mode, KILL becomes "kill the process group" — equivalent effect, different mechanism. The cooperative `TERM` signal (file-based) is unaffected, as it operates at the agent level regardless of backend.

### UNIX Philosophy Alignment

> **Rule of Separation**: *"Separate policy from mechanism; separate interfaces from engines."*

Maintained. `CEKERNEL_TERMINAL=headless` is policy; `backends/headless.sh` is mechanism. The env var dispatch pattern from ADR-0001 is preserved without modification.

> **Rule of Modularity**: *"Write simple parts connected by clean interfaces."*

Strengthened. The interface shrinks from 8 functions to 4 external + 3 private. Each function has a clear, universal meaning across all backends. No no-op functions in the external API.

> **Rule of Least Surprise**: *"In interface design, always do the least surprising thing."*

Improved. `backend_spawn_worker` is unsurprising for headless — it spawns a worker. `terminal_spawn_window` for a headless backend would be surprising. Terminal-specific vocabulary (`pane`, `window`, `workspace`) removed from the external API.

> **Rule of Clarity**: *"Clarity is better than cleverness."*

Improved. Handle file encapsulation eliminates callers needing to know whether the handle is a pane ID, pane target, or PID. The unified `kill_worker` removes the `kill_pane` vs `kill_window` ambiguity.

## Alternatives Considered

### Alternative: Flat rename only (no interface reduction)

Rename `terminal_*` → `backend_*` but keep all 8 functions. Headless implements no-ops for `split_pane`, `run_command`, etc.

Rejected: Violates Rule of Modularity. No-op functions in a public interface are a code smell — they signal that the abstraction doesn't fit the domain. Since the 3 internal functions are never called by external callers, removing them from the public API costs nothing.

### Alternative: Separate interface for headless

Define a minimal interface for headless (`spawn`, `alive`, `kill`) and a richer interface for terminal backends. Callers check which interface is available.

Rejected: Violates Rule of Simplicity. Callers would need conditional logic. The 4-function unified interface is sufficient for all backends — terminal-specific richness (layouts, splits) is an internal implementation detail that callers don't need.

## Consequences

### Positive

- Headless backend becomes a ~20-line file with zero no-op functions
- External API surface halves (8 → 4), reducing cognitive load for future backend authors
- Handle file encapsulation eliminates caller-side format assumptions
- SESSION_ID propagation is simplest in headless (direct env var), validating the IPC design

### Negative

- All callers (`spawn-worker.sh`, `health-check.sh`, `cleanup-worktree.sh`) require signature changes
- All test files (3 test suites, ~34 test cases) require updates for renamed functions
- WezTerm/tmux backends need internal restructuring (public → private functions)

### Impact on other ADRs

- **ADR-0001**: Interface reduced from 8 to 4 external functions. ADR-0001 Status updated with cross-reference.
- **ADR-0003**: `KILL` signal semantics change from "kill terminal pane" to "kill process group" in headless mode. Cooperative `TERM` signal (file-based) is unaffected.
- **ADR-0004**: State machine is backend-agnostic (file-based). No changes needed.

### Trade-offs

**Scope vs. minimal change**: The rename + interface reduction is a larger changeset than just adding `backends/headless.sh`. However, doing the rename without the reduction would leave no-op functions that violate Modularity. The marginal cost of the reduction is small (callers already need updating for the rename), and it produces a cleaner long-term interface.

**`kill_pane` precision lost**: The current `kill_pane` (single pane) vs `kill_window` (all panes) distinction is meaningful for terminal backends during rollback. With `backend_kill_worker`, the rollback path kills the entire window rather than just the main pane. This is acceptable — partial window cleanup after a failed spawn has no useful purpose.

## Amendment 1 (2026-07-07): Opaque session-token handles under ADR-0016 delegation

ADR-0016 (Phase 1, #546) delegates headless spawn and supervision to
`claude --bg` background agent sessions. There is no local child process
anymore — the daemon owns it — so the numeric-PID handle model above no
longer applies to the headless backend. This amendment retypes the
interface accordingly. cekernel 2.0.0 is a breaking release: the previous
`claude -p` + `setsid`/process-group mechanism is removed, not switched.

### Interface changes

| Function | Before | After |
|----------|--------|-------|
| `backend_get_pid` | Numeric PID | **Renamed `backend_get_handle`** — returns an opaque worker token: numeric PID for wezterm/tmux (unchanged implementation, `kill -0` checkable), session token for headless |
| `backend_worker_alive` | `kill -0 $PID` (headless) | `claude agents --json` state: `busy`/`blocked` = alive; `done`/`stopped`/not listed = dead |
| `backend_kill_worker` | `kill -- -$PID` process group (headless) | `claude stop <token>` — also reaps lingering `done` sessions (they persist until explicitly stopped) |
| *(new, optional)* `backend_worker_status` | — | Echoes the session state (`busy`\|`blocked`\|`done`\|…), `missing` + exit 1 when undeterminable. Provided by headless; terminal backends gain it in ADR-0016 Phase 5. Callers feature-detect with `declare -F` |

### Handle semantics (headless)

- The handle file (`handle-{issue}.{type}`) contains the **full session
  UUID** captured at spawn (ADR-0016 normative order: short-ID prefix
  match against `agents --json`, then `kind`+`cwd`+`startedAt` fallback),
  or the **short ID** (8 hex chars) as a degraded fallback when the full
  UUID does not resolve. All lookups prefix-match `sessionId`, so both
  forms work for liveness and `claude stop`.
- The token is also persisted to `{type}-{issue}.claude-session-id` in the
  IPC directory. Like `.spawned` files it survives cleanup, giving
  `transcript-locator.sh` a deterministic UUID-direct lookup (#528).

### Ripple: issue-lock holder verification

`spawn.sh` records the worker token in the issue lock. Since headless
tokens are not PIDs, `issue-lock.sh` dispatches on holder shape: numeric →
`kill -0` (unchanged); non-numeric → `claude agents --json` state
(`busy`/`blocked` = alive, terminal/missing = stale, query failure =
conservatively alive — a lock held until explicit release beats duplicate
Workers).

### Supervision: blocked state

`blocked` (session waiting on a permission dialog) is a silent-stall
failure mode unique to delegated sessions. `watch.sh` surfaces it as a
distinct terminal `blocked` result (nobody approves dialogs in a headless
session) and `health-check.sh` reports status `blocked` (exit 1).

### Process-group notes superseded

The `setsid` + `kill -- -$PID` design in the original Decision applied to
locally-forked workers. Under delegation, child-process containment is the
daemon's responsibility; `claude stop` terminates the session and its
processes. ADR-0003's KILL semantics for headless become "stop the
session".
