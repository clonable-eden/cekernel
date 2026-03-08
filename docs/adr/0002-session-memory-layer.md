# ADR-0002: Session memory layer for inter-agent communication

## Status

Accepted (Phase 1 only — Phase 2 deferred until demonstrated need)

## Context

cekernel's inter-agent communication currently routes all shared data through GitHub:

```
Orchestrator                          Worker
     │                                   │
     ├─ gh issue view #4 (triage) ──→ GitHub
     │                                   │
     ├─ spawn-worker.sh ─────────────→ Worker starts
     │   (passes only issue number)      │
     │                                   ├─ gh issue view #4 (same data, 2nd fetch)
     │                                   ├─ gh issue comment (Execution Plan)
     │                                   ├─ gh pr create
     │                                   ├─ gh issue comment (Result)
     │                                   │
     │←──────── FIFO (JSON) ────────────┘
```

This has three concrete costs:

1. **Redundant GitHub API calls**: Orchestrator reads an issue for triage. Worker reads the identical issue again. For N workers, the same issue is fetched N+1 times (once by Orchestrator, once by each Worker). With GitHub's rate limit of 5,000 requests/hour, a busy session can approach this limit.

2. **Context window waste**: Both Orchestrator and Worker ingest the full issue body (which can be substantial — multi-section specifications, reproduction steps, discussion threads). This consumes context window capacity — the scarcest resource in an agent system — with duplicate data.

3. **No inter-Worker knowledge sharing**: Worker A may discover that a particular approach doesn't work. Worker B, working on a related issue, has no way to learn this. Each Worker is a fully isolated process with no shared memory.

Meanwhile, the existing IPC directory (`/tmp/cekernel-ipc/{SESSION_ID}/`) already provides session-scoped local storage with FIFOs, pane IDs, and log files. The infrastructure for local data exchange exists but is underutilized.

### Key Constraint

GitHub must remain the **human-facing record**. Execution Plans and Results must always be posted as issue comments. The session memory layer is for agent-to-agent efficiency, not a replacement for human-visible artifacts.

## Decision

Introduce a **local task file** extracted at spawn time as the primary mechanism, with a **session-scoped SQLite database** as the optional second phase for cross-Worker communication.

### Phase 1: Local task file

`spawn-worker.sh` extracts issue data once and writes it to the worktree before launching the Worker:

```
.worktrees/issue/4-feature/
  .cekernel-task.json     ← written by spawn-worker.sh
```

Contents (structured JSON, not markdown):

```json
{
  "issue": 4,
  "title": "Add retry logic to API client",
  "body": "## Background\n...",
  "labels": ["bug", "ready"],
  "comments": [...],
  "fetched_at": "2026-02-26T09:00:00Z"
}
```

Worker reads `.cekernel-task.json` locally instead of calling `gh issue view`. Zero API calls for issue data. Zero context spent parsing GitHub CLI output.

The Worker agent definition (`worker.md`) changes from:

```
Fetch issue: gh issue view <issue-number>
```

to:

```
Read issue from .cekernel-task.json in the worktree root.
If the file is missing, fall back to gh issue view.
```

### Phase 2: Session SQLite (future)

A session-scoped SQLite database for cross-Worker data sharing:

```
/tmp/cekernel-ipc/{SESSION_ID}/
  ├── worker-4          # FIFO (existing)
  ├── logs/             # Logs (existing)
  └── memory.db         # Session memory (WAL mode)
```

Tables:

```sql
CREATE TABLE issue_cache (
  issue_number INTEGER PRIMARY KEY,
  data         JSON NOT NULL,
  fetched_at   TEXT NOT NULL
);

CREATE TABLE worker_notes (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  issue_number INTEGER NOT NULL,
  key          TEXT NOT NULL,
  value        TEXT NOT NULL,
  created_at   TEXT NOT NULL
);
```

`issue_cache` eliminates redundant API calls. `worker_notes` enables cross-Worker knowledge sharing (Worker A writes "approach X failed because Y", Worker B reads it).

SQLite with WAL mode provides concurrent read safety from shell scripts via `sqlite3` — no daemon, no library dependency beyond what ships with macOS and most Linux distributions.

**Phase 2 is explicitly deferred.** The local task file solves the immediate problem (redundant fetches, context waste) with minimal complexity. SQLite is introduced only when a concrete cross-Worker communication need arises.

### UNIX Philosophy Alignment

> Rule of Economy: "Programmer time is expensive; conserve it in preference to machine time."

Context window capacity is the agent equivalent of programmer time — it is the binding constraint. Every token spent re-reading an issue from GitHub is a token unavailable for implementation reasoning. The local task file eliminates this waste at near-zero implementation cost.

> Rule of Representation: "Fold knowledge into data so program logic can be stupid and robust."

Issue data becomes a JSON file on disk. The Worker reads structured data rather than invoking an external CLI and parsing its output. The knowledge (issue content) is in the data (`.cekernel-task.json`), and the logic (Worker reading it) is trivial (`Read` tool on a known path).

> Rule of Composition: "Design programs to be connected with other programs."

The task file is plain JSON. It can be consumed by `jq`, `sqlite3 .import`, `cat`, or any tool that reads files. It does not require a specific client or protocol. This preserves composability — future tools can read the same file without coordination.

> Rule of Optimization: "Prototype before polishing. Get it working before you optimize it."

Phase 1 (local file) is the prototype. Phase 2 (SQLite) is the optimization. The decision explicitly sequences these: solve the immediate problem with the simplest mechanism, then evolve only when empirical need demands it. Jumping straight to SQLite would violate this principle.

> Rule of Separation: "Separate policy from mechanism; separate interfaces from engines."

GitHub comments remain the policy layer (what humans see). The local task file is the mechanism layer (how agents exchange data efficiently). The two concerns are fully decoupled — the Worker still posts Plans and Results to GitHub, but no longer depends on GitHub for reading input data.

## Alternatives Considered

### Alternative: Direct GitHub caching proxy

Build a shell function that wraps `gh issue view` with a file-based cache (keyed by issue number + timestamp). All scripts continue calling `gh issue view` but get cached responses transparently.

Rejected for two reasons:

> Rule of Transparency: "Design for visibility to make inspection and debugging easier."

A transparent cache between the caller and `gh` hides behavior. When a Worker reads stale data, debugging requires understanding the cache layer. The explicit `.cekernel-task.json` file is visible: you can `cat` it, you know exactly when it was written, and it's obvious where the data came from.

Additionally, a caching proxy must handle invalidation — when does a cached issue become stale? The task file sidesteps this entirely: it's written once at spawn time and represents a snapshot, which is semantically correct (the Worker should implement against the issue as it was when work began).

### Alternative: Pass issue body in the spawn prompt

Embed the full issue body directly in the Worker's initial prompt string in `spawn-worker.sh`, instead of writing a file.

Rejected:

> Rule of Parsimony: "Write a big program only when it is clear by demonstration that nothing else will do."

Shell command strings have practical length limits. Large issue bodies with special characters (quotes, backticks, dollar signs) create escaping nightmares. A file on disk has no such constraints and is the natural Unix mechanism for passing structured data between processes. Processes communicate through files and pipes, not through ever-longer argument strings.

### Alternative: Jump directly to SQLite

Skip the local task file and implement SQLite from the start, since it's the "most promising candidate" per the issue description.

Rejected:

> Rule of Simplicity: "Design for simplicity; add complexity only where you must."

SQLite introduces schema management, migration concerns, a new dependency assumption (`sqlite3` availability), and concurrent write coordination (WAL mode configuration). The local task file solves the primary problem (redundant API calls, context waste) with `jq` + file write — tools already used throughout cekernel. Adding SQLite before demonstrating that a simple file is insufficient would be premature complexity.

## Consequences

### Positive

- Eliminates N+1 redundant `gh issue view` calls per session (1 Orchestrator + N Workers → 1 total)
- Reduces Worker context window consumption — structured JSON is more compact than `gh issue view` CLI output
- `spawn-worker.sh` change is ~10 lines (one `gh issue view --json` call + `jq` write)
- `worker.md` change is minimal (prefer local file, fall back to `gh`)
- Phase 2 path to SQLite is clear and non-breaking — the task file can coexist with or be migrated into a database

### Negative

- Task file is a spawn-time snapshot. If the issue is updated after spawn, the Worker sees stale data. This is acceptable because Workers should implement against a stable specification, but it's a behavioral change from the current "always-fresh" `gh issue view`
- Adds one file (`.cekernel-task.json`) to each worktree. Must be `.gitignore`d to avoid accidental commits

### Trade-offs

**Freshness vs. Efficiency**: The task file trades real-time freshness for efficiency. A Worker spawned at 9:00 sees the issue as of 9:00, even if a human edits it at 9:05. This is actually desirable — implementing against a moving target is worse than implementing against a stable snapshot. If the issue changes materially, the correct action is to abort and re-spawn, not to silently pick up changes mid-implementation.

**Simplicity vs. Capability**: Phase 1 deliberately omits cross-Worker communication. Two Workers cannot share discoveries through the task file alone. This capability is deferred to Phase 2 (SQLite), following the Rule of Optimization: get the simple version working first, then add sophistication when the need is demonstrated.

## Amendment: IPC directory migration (#220)

The IPC base directory has been migrated from `/tmp/cekernel-ipc/` to `/usr/local/var/cekernel/ipc/` as part of the runtime state unification (#220, per ADR-0011).

All IPC paths referenced in this ADR — including the Phase 2 example — now reside under `/usr/local/var/cekernel/ipc/{SESSION_ID}/` instead of `/tmp/cekernel-ipc/{SESSION_ID}/`. The session-scoped structure within the directory (FIFOs, logs, state files) is unchanged. Only the parent path has moved.

This migration consolidates all cekernel runtime state (IPC, locks, logs, runners, schedules) under a single namespace, consistent with ADR-0011's design.
