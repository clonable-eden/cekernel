# ADR-0014: Two-Tier Concurrency Control Environment Variables

## Status

Proposed

## Context

`CEKERNEL_MAX_PROCESSES` controlled the number of workers/reviewers an
orchestrator could spawn, but there was no concurrency control for
orchestrators themselves. Now that orchestrators are managed as processes
(PIDs tracked in `orchestrator.pid`, lifecycles visible via `orchctl ps`),
orchestrator-level concurrency control is feasible. Two problems remain:

1. **No upper bound on orchestrators**: `/dispatch` can spawn multiple
   orchestrators in rapid succession. Nothing prevents resource exhaustion.
2. **Ambiguous naming**: `CEKERNEL_MAX_PROCESSES` reads as a system-wide limit,
   but it actually governs children *per orchestrator*. The deprecated
   `CEKERNEL_MAX_WORKERS` further adds confusion by coexisting with priority
   override semantics.

The concurrency model is now two-tiered:

```
system
 └── orchestrator  (bounded by CEKERNEL_MAX_ORCHESTRATORS)
      ├── worker   (bounded by CEKERNEL_MAX_ORCH_CHILDREN per orchestrator)
      ├── worker
      └── reviewer
```

This ADR renames environment variables to match this structure and introduces
orchestrator-level concurrency control.

## Decision

### New variable: `CEKERNEL_MAX_ORCHESTRATORS`

| Attribute | Value |
|-----------|-------|
| Default | `3` |
| Valid values | Positive integer |
| Used by | `dispatch`, `orchestrate`, `orchctl` |
| Purpose | Maximum number of concurrently running orchestrators |

**Counting mechanism**: Add an internal subcommand `orchctl.sh count` that
scans `$IPC_BASE/*/orchestrator.pid`, validates with `kill -0`, and outputs the
number of running orchestrators. This reuses `orchctl.sh`'s existing `IPC_BASE`
resolution logic without duplication. The `count` subcommand is internal — not
exposed in `orchctl.sh`'s usage/help output — intended for programmatic use by
dispatch and orchestrate skills via Bash.

**Enforcement behavior differs by caller**:

- **dispatch** (batch, non-interactive): If running orchestrators >= MAX, exit
  immediately and notify the user via `desktop-notify`. Rationale: dispatch
  processes a queue of issues; blocking indefinitely in a batch context is
  wasteful.
- **orchestrate** (interactive, user-initiated): If running orchestrators >= MAX,
  ask the user whether to wait. If yes, poll `orchctl ps` periodically until a
  slot opens. If no, exit without action.

### Rename: `CEKERNEL_MAX_PROCESSES` → `CEKERNEL_MAX_ORCH_CHILDREN`

| Attribute | Value |
|-----------|-------|
| Default | `3` (or profile value) |
| Valid values | Positive integer |
| Used by | `spawn.sh` |
| Purpose | Maximum concurrent children (workers + reviewers) per orchestrator |

The scope qualifier `ORCH_` makes it unambiguous that this is a per-orchestrator
limit, not a system-wide one.

### Remove: `CEKERNEL_MAX_WORKERS` backward compatibility

`CEKERNEL_MAX_WORKERS` was deprecated in ADR-0006 and replaced by
`CEKERNEL_MAX_PROCESSES`. With this second rename, maintaining a chain of two
deprecated aliases adds complexity for zero benefit. The backward-compatible
fallback and warning in `spawn.sh` are removed.

### No system-wide total limit

With defaults of 3 orchestrators x 3 children = 9 maximum concurrent processes.
A global cap (`CEKERNEL_MAX_TOTAL_PROCESSES`) is not introduced at this time.
If resource exhaustion becomes a practical problem, it can be added later without
breaking the current variables.

### UNIX Philosophy Alignment

> Rule of Clarity: "Clarity is better than cleverness."

`CEKERNEL_MAX_ORCH_CHILDREN` tells the reader exactly what it bounds — children
of an orchestrator. `CEKERNEL_MAX_PROCESSES` required reading the implementation
to understand its scope. The rename trades brevity for precision.

> Rule of Modularity: "Write simple parts connected by clean interfaces."

Two-tier concurrency separates concerns cleanly. Orchestrator-level limits are
checked at spawn time by dispatch/orchestrate. Child-level limits are checked
by `spawn.sh` within each orchestrator's session. Neither layer needs to know
the other's implementation.

> Rule of Least Surprise: "In interface design, always do the least surprising thing."

A variable named `MAX_PROCESSES` in a system that has orchestrators, workers,
and reviewers is ambiguous. Users would reasonably guess it controls the total
number of processes. `MAX_ORCH_CHILDREN` and `MAX_ORCHESTRATORS` eliminate this
ambiguity.

> Rule of Parsimony: "Write a big program only when it is clear by demonstration
> that nothing else will do."

Removing the `CEKERNEL_MAX_WORKERS` backward-compatibility chain simplifies the
concurrency guard in `spawn.sh` from a three-way priority cascade to a single
variable read.

### Platform Constraints

**Orchestrator counting crosses session boundaries**: `orchctl ps` scans
`$IPC_BASE/*/orchestrator.pid` — this works because all sessions share the
same `$IPC_BASE` directory on the filesystem. No inter-session communication
is needed; the filesystem is the coordination point (consistent with
"No Shared State Between Sessions" constraint).

**skill→script invocation**: dispatch and orchestrate skills need to call the
orchestrator count helper. Skills cannot invoke other skills — the Skill tool
is not available within a skill's `allowed-tools`. Additionally, subagent
nesting is unreliable (ADR-0012, claude-code-constraints.md). The skills
therefore invoke the shared counting script directly via Bash.

## Alternatives Considered

### Alternative: `CEKERNEL_MAX_CHILDREN`

Shorter, but ambiguous — children of *what*? In a two-tier model, both
orchestrators (children of the system) and workers (children of an orchestrator)
are "children." The `ORCH_` prefix eliminates this ambiguity at the cost of
four characters.

### Alternative: `CEKERNEL_MAX_PROCS_PER_ORCH`

Descriptive but verbose (22 characters). `CEKERNEL_MAX_ORCH_CHILDREN` (25
characters) is marginally longer but uses "children" which maps directly to the
Unix process tree metaphor (parent/child), whereas "procs" is an abbreviation
that does not appear elsewhere in the variable namespace.

### Alternative: Keep `CEKERNEL_MAX_WORKERS` backward compatibility

Maintaining a deprecation chain (`MAX_WORKERS` → `MAX_PROCESSES` →
`MAX_ORCH_CHILDREN`) adds a three-way priority cascade in `spawn.sh` and
requires documenting the history in every reference. The variable has been
deprecated since ADR-0006. A clean break with release-note notice is preferable.

### Alternative: System-wide total limit (`CEKERNEL_MAX_TOTAL_PROCESSES`)

Adds a third layer of concurrency control. With defaults of 3 x 3 = 9, the
practical limit is already reasonable. Introducing a total cap now would add
configuration complexity without demonstrated need. Can be added later without
breaking changes if resource exhaustion becomes a real issue.

## Consequences

### Positive

- Variable names unambiguously describe their scope
- Orchestrator concurrency is bounded, preventing unbounded resource consumption
- dispatch/orchestrate have appropriate failure modes (fail-fast vs interactive)
- `spawn.sh` concurrency guard is simplified (single variable, no fallback chain)
- Shared counting helper avoids duplicating `orchctl ps` discovery logic

### Negative

- Breaking change: `CEKERNEL_MAX_PROCESSES` and `CEKERNEL_MAX_WORKERS` stop
  working. Users with custom env profiles or exports must update them
- Two variables to configure instead of one (though defaults are sensible)

### Trade-offs

Clarity vs backward compatibility: The rename breaks existing configurations.
This is acceptable because (a) cekernel is pre-1.0 with a small user base,
(b) the old names are actively misleading given the new process model, and
(c) a release-note announcement gives users clear migration instructions.
