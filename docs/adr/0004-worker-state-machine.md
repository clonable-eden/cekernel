# ADR-0004: Formal Worker process state machine

## Status

Accepted

## Context

cekernel's Worker lifecycle visibility is binary: a Worker is either "alive" (FIFO exists) or "dead" (FIFO removed). The scripts that provide observability reflect this:

- `worker-status.sh` (now `process-status.sh`) lists Workers by enumerating FIFOs in the IPC directory. It reports issue number, worktree path, and uptime — but not what the Worker is *doing*.
- `health-check.sh` determines "healthy" (pane alive) or "zombie" (pane dead, FIFO still exists). It cannot distinguish between a Worker actively coding and one stuck waiting on CI.

In Unix terms, this is equivalent to `ps` only showing PIDs without process states. The kernel tracks NEW, READY, RUNNING, WAITING, TERMINATED — cekernel tracks nothing between spawn and completion.

This limits the Orchestrator's ability to make informed decisions:

- **Scheduling**: When should the next Worker be spawned? If a Worker is WAITING on CI, its CPU (context window) is idle — a new Worker could be spawned even at the concurrency limit.
- **Diagnostics**: "Worker 4 has been running for 2 hours" — is it stuck, or is CI slow? Without state, the Orchestrator cannot distinguish between a productive Worker and a stuck one.
- **Dependency coordination**: Worker B depends on Worker A's merge. When does A transition from RUNNING to WAITING to TERMINATED? Without state tracking, B must poll GitHub to check if A's PR was merged.

## Decision

Introduce a **state file per Worker** in the IPC directory. Workers update their state at phase transitions. Observability scripts read state files for richer output.

### State model

```
SPAWNING → PLANNING → RUNNING → PR_CREATED → CI_WAITING → MERGING → COMPLETED
                                                  ↑  ↓         ↑
                                                  CI_FIXING ───┘
                                                     ↓
                                                   FAILED (after 3 retries)
                                                          → CANCELLED (via signal, ADR-0003)
```

States map to the Worker protocol phases defined in `worker.md`:

| State | Written by | Phase | Meaning |
|-------|-----------|-------|---------|
| `SPAWNING` | `spawn-worker.sh` | — | Worktree created, agent starting |
| `PLANNING` | Worker | Phase 0 | Reading CLAUDE.md, fetching issue, drafting plan |
| `RUNNING` | Worker | Phase 1 | Implementing (TDD cycles) |
| `PR_CREATED` | Worker | Phase 2 | PR pushed and created |
| `CI_WAITING` | Worker | Phase 3 | Waiting on CI checks |
| `CI_FIXING` | Worker | Phase 3 | CI failed, fixing and re-pushing (up to 3 retries) |
| `MERGING` | Worker | Phase 3 | CI passed, merge in progress |
| `COMPLETED` | Worker | Phase 4 | Merged and notified |
| `FAILED` | Worker | any | Unrecoverable error (including 3 CI failures) |
| `CANCELLED` | Worker | any | Received TERM signal (ADR-0003) |

The `CI_WAITING → CI_FIXING → CI_WAITING` cycle corresponds to the Worker protocol's On Error section, which allows up to 3 CI retry attempts before reporting failure.

### State file format

```
/usr/local/var/cekernel/ipc/{SESSION_ID}/
  ├── worker-4              # FIFO (existing)
  ├── worker-4.state        # NEW: state file
  └── ...
```

Content — a single line of plain text:

```
CI_WAITING
```

No JSON, no structured format. A state is a single token. This is deliberate:

- `cat worker-4.state` returns the state immediately
- `grep -l CI_WAITING *.state` finds all Workers in CI
- No parsing library, no schema, no version management

### State transitions (Worker side)

The Worker writes its state file at each phase boundary. In `worker.md`, this translates to:

```
On startup:       echo PLANNING > $STATE_FILE
Before Phase 1:   echo RUNNING > $STATE_FILE
Before Phase 2:   echo PR_CREATED > $STATE_FILE
Before Phase 3:   echo CI_WAITING > $STATE_FILE
On CI failure:    echo CI_FIXING > $STATE_FILE
After fix + push: echo CI_WAITING > $STATE_FILE   (cycle up to 3 times)
Before merge:     echo MERGING > $STATE_FILE
Phase 4:          echo COMPLETED > $STATE_FILE
On error:         echo FAILED > $STATE_FILE
On signal:        echo CANCELLED > $STATE_FILE
```

`spawn-worker.sh` writes the initial `SPAWNING` state before launching the Worker agent.

### State consumption (Orchestrator side)

`worker-status.sh` gains a `state` field in its JSON output:

```json
{"issue": 4, "worktree": "...", "fifo": "...", "uptime": "12m", "state": "CI_WAITING"}
```

`health-check.sh` can use state for more precise zombie detection:

- State is `RUNNING` or `CI_FIXING` but pane is dead → zombie (certain)
- State is `CI_WAITING` and pane is dead → possibly expected (CI can outlive the pane in headless mode per ADR-0001)
- State is `SPAWNING` for > 5 minutes → likely stuck
- State is `CI_FIXING` for > 30 minutes → possibly stuck in fix loop

### UNIX Philosophy Alignment

> Rule of Transparency: "Design for visibility to make inspection and debugging easier."

This is the primary motivation. A state file makes Worker behavior immediately visible. `ls *.state && cat *.state` gives a complete picture of all Workers' current activities. No need to infer state from pane liveness, FIFO existence, or process detection — the Worker declares what it is doing.

> Rule of Representation: "Fold knowledge into data so program logic can be stupid and robust."

Worker state moves from implicit inference (is the FIFO present? is the pane alive? is there a process in the worktree?) to explicit data (a file containing one word). `worker-status.sh` no longer needs heuristics — it reads a file. `health-check.sh` gains precision without gaining complexity. The knowledge of what the Worker is doing lives in the data, not in the deduction logic.

> Rule of Silence: "When a program has nothing surprising to say, it should say nothing."

State transitions are written to a file, not printed to stdout. Observability scripts read the file only when asked. The Worker does not broadcast its state changes — it records them silently, and consumers query when needed. This avoids noise in the FIFO channel (which remains dedicated to completion notification) and in terminal output.

> Rule of Composition: "Design programs to be connected with other programs."

State files are plain text, one token per file. They compose trivially:

```bash
# Count Workers in each state
for f in *.state; do cat "$f"; done | sort | uniq -c

# Find Workers waiting on CI
grep -l CI_WAITING *.state | sed 's/.state//' | sed 's/worker-//'

# Watch state transitions in real time
watch 'for f in *.state; do echo "$(basename $f .state): $(cat $f)"; done'
```

No special tooling required. Standard Unix tools work out of the box.

## Alternatives Considered

### Alternative: JSON state file with history

Store full state history in a JSON array:

```json
[
  {"state": "SPAWNING", "at": "2026-02-26T09:00:00Z"},
  {"state": "PLANNING", "at": "2026-02-26T09:00:15Z"},
  {"state": "RUNNING", "at": "2026-02-26T09:01:02Z"}
]
```

Rejected:

> Rule of Simplicity: "Design for simplicity; add complexity only where you must."

State history is a debugging luxury, not an operational necessity. The Orchestrator needs to know the *current* state, not the history. Appending JSON arrays atomically from bash is error-prone (concurrent writes, valid JSON maintenance). If history is needed, the existing log files (`worker-N.log`) already record lifecycle events with timestamps. Adding structured history to the state file duplicates the log's responsibility.

### Alternative: State encoded in FIFO filename

Rename the FIFO to encode state: `worker-4-RUNNING`, `worker-4-CI_WAITING`.

Rejected:

> Rule of Least Surprise: "In interface design, always do the least surprising thing."

Every script that references FIFOs uses the pattern `worker-{issue}`. Changing FIFO names at runtime would break `watch-worker.sh` (now `watch.sh`) (which opens FIFOs by known path), `notify-complete.sh` (which writes to a known path), `health-check.sh` (which finds FIFOs by glob), and `cleanup-worktree.sh` (which removes FIFOs by known path). A renaming FIFO violates the expectation that IPC endpoints have stable names.

### Alternative: Central state database (SQLite)

Store all Worker states in the session SQLite database proposed in ADR-0002.

This is viable and may be the right choice if/when SQLite is introduced. However:

> Rule of Optimization: "Prototype before polishing. Get it working before you optimize it."

Individual state files are the simplest implementation that works. One file per Worker, one word per file. If ADR-0002's Phase 2 (SQLite) materializes, migrating from files to a `worker_states` table is trivial — the state values and transition semantics remain identical. Starting with files avoids coupling this feature to the SQLite decision.

## Consequences

### Positive

- `worker-status.sh` output gains a `state` field, transforming it from an uptime counter to a real dashboard
- `health-check.sh` gains precision: state + pane liveness together distinguish "working", "waiting", "stuck", and "dead"
- Enables smarter scheduling: Orchestrator can spawn new Workers when existing ones enter `CI_WAITING` (context window is idle)
- Foundation for #77 (priority): state-aware scheduling decisions require knowing what Workers are doing
- Foundation for #79 (cron): automated triage needs to assess current Worker load and capacity
- Implementation cost is minimal: `echo STATE > file` at ~6 points in Worker lifecycle, `cat file` in 2 observability scripts

### Negative

- Worker agent definition (`worker.md`) gains state-writing instructions at each phase boundary — incremental complexity
- State files can become stale if a Worker crashes without updating (same limitation as any cooperative mechanism)
- Adds N files to the IPC directory (one per Worker), though these are tiny (single-word files)

### Trade-offs

**Precision vs. Simplicity**: The state model has 10 states. A simpler model (e.g., 3 states: ACTIVE, WAITING, DONE) would be easier to manage but less useful for diagnostics. The 10-state model maps 1:1 to Worker protocol phases (including the CI retry loop), which means no interpretation is needed — the state name tells you exactly which phase the Worker is in. The marginal cost of more states is near zero (it's still one word in a file), while the diagnostic value is significant.

**Cooperative vs. Authoritative**: Workers self-report their state. A crashing Worker may leave a stale `RUNNING` state file. This is mitigated by `health-check.sh`, which cross-references state with pane liveness: if state says `RUNNING` but the pane is dead, the Worker is a zombie regardless of what the state file claims. The state file is advisory, not authoritative — it improves observability but is not the sole source of truth.

## Review Notes

The following modifications were made during review:

### Added `CI_FIXING` state

The original proposal only modeled the happy path (`CI_WAITING → MERGING`). The Worker protocol (`worker.md` On Error section) defines a CI retry loop with up to 3 attempts. The `CI_FIXING` state was added to make this loop visible in the state model:

```
CI_WAITING → CI fails → CI_FIXING (fix, test, commit, push) → CI_WAITING (retry)
                              ↓ after 3 failures
                            FAILED
```

This also improves `health-check.sh` diagnostics: `CI_FIXING` for >30 minutes indicates a Worker potentially stuck in a fix loop.

### Consistency with ADR-0002 (file-based approach)

Alternative 3 (SQLite) was correctly deferred per Rule of Optimization. ADR-0002 was accepted as Phase 1 (file-based) only, which aligns with this ADR's choice of individual state files over a database. Both ADRs follow the same principle: start with files, migrate to SQLite only when demonstrated need arises.

### Related: CI retry count (#82)

During review, the hardcoded 3-retry limit in the Worker protocol was identified as a potential improvement area. Filed as #82 (separate from this ADR, as retry policy is a Worker protocol concern, not a state machine concern).

### Amendment: Worker-Reviewer separation (ADR-0012)

ADR-0012 splits the Worker lifecycle at the CI pass boundary. The following states are affected:

- **`MERGING` removed**: Workers no longer merge. The `RUNNING:phase3:merging` state is deleted from the model.
- **`COMPLETED` → `CI_PASSED`**: The Worker's terminal success state changes from `TERMINATED:merged` to `TERMINATED:ci-passed`. Merge is now the Orchestrator's responsibility after Reviewer approval.

Updated state model:

```
SPAWNING → PLANNING → RUNNING → PR_CREATED → CI_WAITING → CI_PASSED (terminal)
                                                  ↑  ↓
                                                  CI_FIXING ───┘
                                                     ↓
                                                   FAILED (after CEKERNEL_CI_MAX_RETRIES)
                                                          → CANCELLED (via signal, ADR-0003)
```

The transition from `CI_PASSED` to merged (or back to `RUNNING` via re-spawn after Reviewer rejection) is managed by the Orchestrator, not the Worker.
