# ADR-0015: Boundary Between cekernel and `/workflows`

## Status

Proposed

## Context

Claude Code added dynamic `/workflows` (v2.1.154+, research preview): a
JavaScript script deterministically orchestrates subagents via `agent()`,
`parallel()`, `pipeline()`, and `phase()`. This overlaps with cekernel's
Orchestrator/Worker model on the surface — both fan out parallel agents —
so the boundary must be explicit (#527).

### `/workflows` characteristics (observed on claude v2.1.201)

- Script-driven deterministic control flow; intermediate results live in
  script variables, not in the calling session's context window.
- Concurrency cap `min(16, cpu cores - 2)` per workflow; 1000 agents per
  run lifetime; 4096 items per `pipeline()`/`parallel()` call.
- Agents are **subagents of the running session**: they can take
  `isolation: 'worktree'` per call, share the session's MCP/tool surface,
  and return structured output via JSON schema.
- Resume (`resumeFromRunId`) replays cached `agent()` results — but
  **same-session only**. `Date.now()`/`Math.random()` are banned inside
  scripts precisely because state must be replayable, not persistent.
- Invocation is gated on **explicit user opt-in** (e.g. "use a workflow",
  ultracode mode, or a skill that instructs it). An agent cannot silently
  choose workflow-scale orchestration on its own.

### The overlap is narrower than it looks

| Axis | cekernel | `/workflows` |
|------|----------|--------------|
| Isolation unit | OS process + named git worktree | Subagent (optional anonymous worktree) |
| State | Files: state / checkpoint / task / FIFO / issue lock | Script variables + run journal |
| Survives the session | Yes — OS scheduler, `--bg` daemon (ADR-0016) | No |
| Time horizon | Hours–days (CI waits, human review, retries) | One session's wall-clock |
| Identity | Issue number = PID; PR/branch conventions | Anonymous agent index |
| Trigger | Event-driven (FIFO, cron/at, human) | Single deterministic run |

cekernel's essence is the **persistence layer**: lifecycles that outlive any
single session. `/workflows`' essence is **deterministic intra-session
fan-out**. The overlap is only "several agents run in parallel."

## Decision

1. **cekernel does not adopt `/workflows` as its orchestration engine.**
   The issue lifecycle (intake → worktree → Worker → PR → CI → review →
   merge → cleanup) remains cekernel's: it is event-driven, spans sessions,
   and must survive process death. A workflow run cannot resume after its
   session ends, which disqualifies it for this role by construction.

2. **Boundary rule: state that must survive the session belongs to
   cekernel; fan-out that completes within a session belongs to
   `/workflows`.**

3. **Agents inside cekernel MAY use `/workflows` within their own
   session.** A Worker tackling one issue with a wide internal fan-out
   (e.g. a migration sweep or multi-dimension self-review), or a Reviewer
   running a find→verify pipeline, may run a workflow — it is an
   implementation detail of that agent's single task, invisible to
   cekernel's lifecycle. The skill/agent definition must instruct it
   explicitly (the opt-in gate requires this).

4. **cekernel provides no wrapper, no abstraction, and no config surface
   for `/workflows`** (Rule of Parsimony). No `CEKERNEL_*` variable
   references workflows. If `/workflows` later gains cross-session resume,
   this ADR must be revisited before any integration.

5. **`dispatch` priority scoring stays in cekernel** (simple, file-based,
   ADR-0008). Delegating a scalar scoring pass to a workflow would add a
   research-preview dependency to a solved problem.

### Relationship to sibling primitives

- **`claude --bg` / `claude agents`** — cekernel *does* delegate spawn and
  supervision to these (ADR-0016). The difference: background sessions are
  independent, persistent, and addressable — exactly the properties the
  issue lifecycle needs and `/workflows` lacks.
- **ADR-0008 (scheduling policy)** — governs cross-process scheduling of
  Workers; workflow `pipeline()` stages schedule subagent calls inside one
  session. Orthogonal; no amendment needed.
- **ADR-0012 Amendment 2** — the Reviewer becomes a subagent; if a future
  Reviewer needs per-finding verifier fan-out, that is a legitimate
  `/workflows` use under rule 3.

## Alternatives Considered

### Alternative: Rebuild the Orchestrator on `/workflows`

Model the issue lifecycle as a long workflow script (spawn phase → CI
phase → review phase).

- **Pro**: deterministic control flow, standard progress UI
- **Con**: a workflow dies with its session; CI waits and human review span
  sessions. Every recovery path would need file-based state anyway —
  reintroducing cekernel inside a workflow.
- **Con**: research preview; 16-concurrency and same-session resume are
  hard ceilings cekernel does not control.
- **Rejected**: wrong persistence model for the core lifecycle.

### Alternative: Wrap `/workflows` behind a cekernel skill

A `/cekernel:workflow` skill that templates common fan-outs.

- **Pro**: discoverability
- **Con**: policy without mechanism — pure indirection over a standard
  feature that users can invoke directly (Rule of Least Surprise favors
  the upstream interface).
- **Rejected**: no added value; maintenance cost on a moving preview API.

## Consequences

### Positive

- The division of labor is one sentence: **cekernel persists, `/workflows`
  fans out.** Contributors can route new features without re-deriving the
  analysis.
- cekernel takes zero dependency on a research-preview API; upstream
  changes to `/workflows` cannot break cekernel.
- Workers/Reviewers keep access to workflow-scale parallelism where it is
  genuinely useful (single-task fan-out), with the opt-in documented.

### Negative

- Two orchestration vocabularies coexist in the ecosystem; users must
  learn the boundary. Mitigation: add a short "when to use which" section
  to README (implementation follow-up).
- If `/workflows` gains cross-session resume, part of this ADR's rationale
  weakens — flagged as an explicit revisit trigger in Decision 4.

## Follow-ups

- README: user-facing "cekernel vs `/workflows`" guide (one table, one
  paragraph).
- `agents/worker.md` / `agents/reviewer.md`: note that workflow use is
  permitted for single-task fan-out when a skill instructs it.
