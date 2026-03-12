# ADR-0008: Orchestrator scheduling policy

## Status

Accepted

## Context

cekernel's Layer 0 and Layer 1 delivered substantial infrastructure for Worker control:

| Infrastructure | Script | ADR |
|---|---|---|
| Signal delivery | `send-signal.sh`, `check-signal.sh` | ADR-0003 |
| State machine | `worker-state.sh` | ADR-0004 |
| Priority / nice value | `worker-priority.sh`, `spawn-worker.sh --priority` | — |
| Context swap | `checkpoint-file.sh`, `spawn-worker.sh --resume` | — |

However, these primitives are **mechanisms without policy**. The Orchestrator (`orchestrator.md`) documents priority-based scheduling as a protocol but does not define *when* to exercise its powers:

- `send-signal.sh` exists, but the Orchestrator never sends signals
- `worker-priority.sh` records priority, but the Orchestrator does not sort its queue by priority
- `checkpoint-file.sh` and `--resume` are functional, but no trigger for SUSPEND exists
- `worker-state.sh` tracks state, but Workers do not write intermediate transitions (RUNNING, WAITING), and the Orchestrator does not use state for scheduling decisions

In Unix terms, the kernel has system calls (`kill(2)`, `nice(2)`, `waitpid(2)`) but the scheduler has no policy. This ADR defines the scheduling policy — the rules governing *when* and *why* the Orchestrator acts.

### Constraint: cooperative, not preemptive

cekernel Workers are Claude Code agents. They cannot be interrupted mid-turn (see ADR-0003 Review Notes). All control is cooperative: Workers check for signals at phase boundaries, and state transitions are self-reported. The scheduling policy must work within this constraint.

### Constraint: Orchestrator is also a Claude agent

The Orchestrator itself runs as a Claude Code agent (`orchestrator.md`). Its "scheduling logic" is not executable code but *instructions in a prompt*. Policy must be expressible as clear, unambiguous rules that an LLM agent can follow. Complex algorithms (e.g., multi-level feedback queues) are inappropriate — the Orchestrator needs simple, deterministic decision rules.

## Decision

### 1. Priority-sorted queue

When more issues are queued than `CEKERNEL_MAX_WORKERS`（deprecated、現 `CEKERNEL_MAX_PROCESSES`） allows, the Orchestrator sorts the queue by nice value (ascending) before spawning. This is the Unix `nice` model: lower value = higher priority = spawned first.

Priority is assigned at issue intake by the Orchestrator. The default is `normal` (10). The user may specify priority via the `/cekernel:orchestrate` skill's `--priority` flag or the future `/cekernel:orchctrl nice` command.

**Decision rule**: Before each spawn, select the issue with the lowest nice value from the queue. On ties, preserve original order (FIFO within priority class).

### 2. Timeout → TERM signal

When `watch-worker.sh` reports timeout, the Orchestrator sends a TERM signal before resorting to force-kill:

```
timeout detected
  → send-signal.sh <issue> TERM
  → wait grace period (CEKERNEL_TERM_GRACE_PERIOD, default: 120s)
  → if still alive: cleanup-worktree.sh --force <issue>
```

This replaces the current behavior of immediate force-kill on timeout. The grace period allows the Worker to commit progress, post status, and exit cleanly.

**New environment variable**: `CEKERNEL_TERM_GRACE_PERIOD` (default: 120 seconds). Configurable via env profiles.

### 3. Preemption via SUSPEND

When a high-priority issue arrives and all Worker slots are full, the Orchestrator may SUSPEND a lower-priority Worker to free a slot:

**Decision rules**:

1. Preemption is triggered only when: (a) all slots are full, AND (b) the incoming issue's nice value is strictly lower than the highest nice value among running Workers
2. The Worker with the highest nice value (lowest priority) is selected for SUSPEND
3. On ties, the Worker with the longest elapsed time is selected (it has had the most opportunity to make progress)
4. The Orchestrator sends SUSPEND signal, waits up to `CEKERNEL_TERM_GRACE_PERIOD` (default: 120s) for the Worker to checkpoint and exit, then spawns the high-priority issue in the freed slot
5. If the Worker does not exit within the grace period, escalate: send TERM, wait another grace period, then force-kill via `cleanup-worktree.sh --force`

```
incoming issue (nice=0, critical) arrives, all 3 slots full:
  Worker A: nice=5  (high)
  Worker B: nice=10 (normal)
  Worker C: nice=15 (low)
  → SUSPEND Worker C (highest nice value)
  → spawn critical issue in freed slot
```

**Guard rails**:

- A Worker can only be suspended if it has been running for at least `CEKERNEL_MIN_RUNTIME` (default: 300s / 5 minutes). This prevents thrashing: a Worker that just started should not be immediately suspended.
- A Worker in state TERMINATED, SUSPENDED, or NEW/READY cannot be suspended (only RUNNING/WAITING Workers).
- At most one preemption per scheduling cycle. The Orchestrator does not cascade-suspend multiple Workers in a single decision.

**New environment variable**: `CEKERNEL_MIN_RUNTIME` (default: 300 seconds).

**Escalation chain** (reuses `CEKERNEL_TERM_GRACE_PERIOD` — no new variable):

```
SUSPEND signal sent
  → wait CEKERNEL_TERM_GRACE_PERIOD (default: 120s)
  → if Worker checkpointed and exited: done (slot freed)
  → if still alive: send TERM signal (escalate to graceful shutdown)
    → wait CEKERNEL_TERM_GRACE_PERIOD again
    → if still alive: cleanup-worktree.sh --force (KILL equivalent)
```

This mirrors the timeout escalation (Decision 2) and reuses the same grace period variable, keeping configuration surface minimal.

### 4. Auto-resume of SUSPENDED Workers

When a Worker slot becomes available and there are SUSPENDED Workers, the Orchestrator resumes them:

**Decision rules**:

1. After cleanup of a completed Worker, check for SUSPENDED Workers in the session
2. Resume the SUSPENDED Worker with the lowest nice value (highest priority) first
3. SUSPENDED Workers take precedence over queued (not-yet-started) issues at the same priority level — they have already made progress and are cheaper to resume than to restart
4. Resume uses `spawn-worker.sh --resume <issue>` which reuses the existing worktree and passes the checkpoint to the new Worker instance

```
Worker A completes → slot freed
  SUSPENDED: Worker C (nice=15)
  Queued: issue #9 (nice=15)
  → Resume Worker C (SUSPENDED takes precedence at equal priority)
```

### 5. Worker state reporting at phase boundaries

Workers write their state at each phase boundary using `worker_state_write`. This makes Worker activity visible to `worker-status.sh`, `health-check.sh`, and the Orchestrator.

State transitions map to Worker protocol phases:

| Phase boundary | State | Detail |
|---|---|---|
| Phase 0 start | RUNNING | `phase0:plan` |
| Phase 1 start | RUNNING | `phase1:implement` |
| Phase 2 start | RUNNING | `phase2:create-pr` |
| Phase 3 start | WAITING | `phase3:ci-waiting` |
| CI fix cycle | RUNNING | `phase3:ci-fixing` |
| Phase 3 merge | RUNNING | `phase3:merging` |
| Phase 4 | TERMINATED | (via `notify-complete.sh`) |

This uses the 6-state model already implemented in `worker-state.sh` (NEW, READY, RUNNING, WAITING, SUSPENDED, TERMINATED) rather than the 10-state model proposed in ADR-0004. The detail field provides phase-level granularity without expanding the state enum.

**Rationale for 6 states over 10**: The `worker_state_write` API already accepts a free-text detail parameter (`STATE:TIMESTAMP:detail`). Phase-specific information belongs in the detail field, not in the state enum. Adding states like `PR_CREATED`, `CI_WAITING`, `CI_FIXING`, `MERGING` to the enum would require changes to `worker-state.sh` validation, `health-check.sh` case statements, and any future consumer. The detail field achieves the same diagnostic value with zero code changes.

**Relationship with ADR-0004**: ADR-0004 proposed a 10-state enum (SPAWNING, PLANNING, RUNNING, PR_CREATED, CI_WAITING, CI_FIXING, MERGING, COMPLETED, FAILED, CANCELLED) as the state model. The implementation (`worker-state.sh`) adopted a simplified 6-state enum (NEW, READY, RUNNING, WAITING, SUSPENDED, TERMINATED). This ADR formalizes the 6-state model as the definitive state enum, with the detail field providing the phase-level granularity that ADR-0004's additional states intended. ADR-0004's state definitions should be read as the conceptual model; the implementation mapping is: SPAWNING→NEW, PLANNING/RUNNING/CI_FIXING/MERGING→RUNNING, PR_CREATED/CI_WAITING→WAITING, COMPLETED/FAILED/CANCELLED→TERMINATED (with detail field distinguishing success/failure/cancellation).

### UNIX Philosophy Alignment

> Rule of Separation: "Separate policy from mechanism; separate interfaces from engines."

This is the central principle. ADR-0003 through ADR-0004 built the mechanisms (signal files, state files, priority files, checkpoint files). This ADR defines the policy (when to signal, how to order, when to preempt). The separation is clean: changing preemption rules requires editing `orchestrator.md` only — no mechanism scripts need modification. Conversely, changing signal delivery (e.g., from files to a database) requires editing scripts only — the policy rules remain valid.

> Rule of Simplicity: "Design for simplicity; add complexity only where you must."

Each policy rule is a simple conditional:

- Timeout → TERM → grace period → KILL. Linear, no branching.
- Preemption: single comparison (incoming nice < max running nice). No multi-factor scoring.
- Resume: SUSPENDED before queued at equal priority. Single tiebreaker.

An LLM agent can follow these rules reliably because each decision is a single comparison, not a complex algorithm.

> Rule of Transparency: "Design for visibility to make inspection and debugging easier."

Workers write state at every phase boundary, making their progress visible via `worker-status.sh`. The Orchestrator's scheduling decisions (why it suspended Worker C, why it resumed Worker B) should be logged to the session log. All state files, priority files, and signal files are inspectable on disk.

> Rule of Least Surprise: "In interface design, always do the least surprising thing."

The policy mirrors Unix conventions:

- Nice values work like Unix `nice(1)`: lower = higher priority, default 10, range 0-19
- TERM before KILL mirrors the Unix convention of `SIGTERM` → grace → `SIGKILL`
- SUSPENDED Workers resume when slots free, like Unix process resumption after `SIGCONT`
- The `orchctrl` skill (future, #125) maps to `kill`, `renice`, `ps` — familiar Unix operations

> Rule of Composition: "Design programs to be connected with other programs."

The policy is defined in `orchestrator.md` (agent prompt) but can be overridden at any time via `orchctrl` (#125). A user can manually `orchctrl suspend 4` regardless of what the automatic policy would decide. The Orchestrator's policy is the *default*, not the only path — manual control composes with automatic scheduling.

## Alternatives Considered

### Alternative: Work-conserving scheduler (no preemption)

Never SUSPEND running Workers. When all slots are full, queue incoming issues regardless of priority. Only spawn when a slot naturally frees.

Rejected:

> Rule of Least Surprise: "In interface design, always do the least surprising thing."

If a user marks issue #42 as `critical` and runs `/cekernel:orchestrate`, they expect it to start soon. A work-conserving scheduler would force the critical issue to wait behind three `low`-priority refactoring tasks. This violates the user's expectation that priority influences scheduling.

The preemption model is also more Unix-like: Unix schedulers preempt low-priority processes when high-priority processes arrive. cekernel should behave similarly.

### Alternative: Multi-level feedback queue

Dynamically adjust Worker priority based on behavior: Workers that complete quickly get boosted, Workers that time out get demoted. Sophisticated scheduling with multiple priority tiers.

Rejected:

> Rule of Simplicity: "Design for simplicity; add complexity only where you must."

The Orchestrator is an LLM agent interpreting a prompt, not a compiled scheduler. Complex algorithms with dynamic state tracking are fragile in this execution model — the agent may misapply rules, lose track of state across turns, or make inconsistent decisions. Simple, static rules are robust and predictable. cekernel's workload (typically 3-6 Workers per session) does not justify algorithmic sophistication.

### Alternative: State-aware scheduling (spawn during CI_WAITING)

When a Worker enters `WAITING` (CI), consider its context window "idle" and spawn an additional Worker beyond `MAX_WORKERS`.

Rejected:

> Rule of Simplicity: "Design for simplicity; add complexity only where you must."

This conflates two resources: Worker slots (bounded by `MAX_WORKERS`) and "cognitive load" (context window activity). A Worker in `WAITING` still occupies a worktree, a FIFO, state files, and backend resources (tmux pane or headless process). Spawning beyond `MAX_WORKERS` during CI waits creates a variable concurrency level that is hard to reason about and hard to predict resource consumption for. The fixed `MAX_WORKERS` limit is simple, predictable, and sufficient.

## Consequences

### Positive

- Priority-sorted spawning ensures urgent work starts first without user intervention
- TERM before KILL preserves Worker progress on timeout, reducing wasted work
- Preemption enables responsive scheduling for critical issues without waiting for natural completion
- Auto-resume prevents SUSPENDED Workers from being forgotten — they rejoin the queue automatically
- State reporting at phase boundaries makes Worker progress visible to all consumers
- All policy rules are simple conditionals, suitable for LLM agent execution

### Negative

- Preemption adds complexity to the Orchestrator prompt: SUSPEND decision, grace period tracking, resume logic
- Two new environment variables (`CEKERNEL_TERM_GRACE_PERIOD`, `CEKERNEL_MIN_RUNTIME`) increase configuration surface
- SUSPENDED Workers consume worktree disk space while waiting for resume — long SUSPEND periods may accumulate worktrees
- Cooperative preemption has latency: a Worker deep in Phase 1 may take minutes to checkpoint after receiving SUSPEND

### Trade-offs

**Responsiveness vs. Stability**: Preemption enables responsive scheduling for critical issues, but introduces the risk of thrashing: if priorities change frequently, Workers may be repeatedly suspended and resumed without making progress. The `CEKERNEL_MIN_RUNTIME` guard (5 minutes) mitigates this by ensuring Workers get meaningful runtime before they can be suspended.

**Simplicity vs. Optimality**: The policy uses single-factor decisions (nice value only) rather than multi-factor scoring (nice + elapsed time + state + resource consumption). This is suboptimal in theory — a smarter scheduler could make better decisions. But the Orchestrator is an LLM agent, not a compiled program. Simple rules it can follow reliably are better than optimal rules it might misapply.

**6-state vs. 10-state model**: ADR-0004 proposed 10 states (SPAWNING, PLANNING, RUNNING, PR_CREATED, CI_WAITING, CI_FIXING, MERGING, COMPLETED, FAILED, CANCELLED). The implementation uses 6 (NEW, READY, RUNNING, WAITING, SUSPENDED, TERMINATED) with phase detail in a free-text field. This sacrifices type-safety (any string can go in the detail field) for pragmatism (zero code changes, existing validation logic works as-is). The trade-off is acceptable because the primary consumers (humans reading `worker-status.sh` output, the Orchestrator reading state) benefit equally from `WAITING:phase3:ci-waiting` as from a dedicated `CI_WAITING` state.
