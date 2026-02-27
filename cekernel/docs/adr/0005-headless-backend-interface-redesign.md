# ADR-0005: Headless Backend and Interface Redesign

## Status

Proposed

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
```

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
  cd "$worktree"
  CEKERNEL_SESSION_ID="$CEKERNEL_SESSION_ID" \
    claude --agent cekernel:worker "$prompt" \
    > "${CEKERNEL_IPC_DIR}/logs/worker-${issue}.stdout.log" 2>&1 &
  echo $! > "${CEKERNEL_IPC_DIR}/handle-${issue}"
}

backend_worker_alive() {
  local pid; pid=$(cat "${CEKERNEL_IPC_DIR}/handle-${1}")
  kill -0 "$pid" 2>/dev/null
}

backend_kill_worker() {
  local pid; pid=$(cat "${CEKERNEL_IPC_DIR}/handle-${1}")
  kill "$pid" 2>/dev/null
}
```

SESSION_ID propagation becomes a direct environment variable pass — simpler than WezTerm OSC or tmux send-keys.

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

### Trade-offs

**Scope vs. minimal change**: The rename + interface reduction is a larger changeset than just adding `backends/headless.sh`. However, doing the rename without the reduction would leave no-op functions that violate Modularity. The marginal cost of the reduction is small (callers already need updating for the rename), and it produces a cleaner long-term interface.

**`kill_pane` precision lost**: The current `kill_pane` (single pane) vs `kill_window` (all panes) distinction is meaningful for terminal backends during rollback. With `backend_kill_worker`, the rollback path kills the entire window rather than just the main pane. This is acceptable — partial window cleanup after a failed spawn has no useful purpose.
