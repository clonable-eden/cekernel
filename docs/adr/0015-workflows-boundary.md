# ADR-0015: Boundary Between cekernel and `/workflows`

## Status

Proposed

## Context

Claude Code added dynamic `/workflows` (v2.1.154+, research preview): a
JavaScript script deterministically orchestrates subagents via `agent()`,
`parallel()`, `pipeline()`, and `phase()`. This overlaps with cekernel's
Orchestrator/Worker model on the surface — both fan out parallel agents —
so the boundary must be explicit (#527).

### `/workflows` characteristics

Platform observations (concurrency caps, same-session-only resume, the
explicit opt-in gate, determinism constraints) are recorded in
[`docs/claude-code-constraints.md`](../claude-code-constraints.md#dynamic-workflows-workflows)
under **Confidence: Evolving**. The properties that drive this ADR:
intermediate results never enter the calling session's context window,
runs cannot resume once their session ends, and invocation requires an
explicit opt-in (an agent cannot silently choose workflow-scale
orchestration on its own).

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
   explicitly (the opt-in gate requires this). **This decision must not be
   exercised until the Open questions below are verified** — the opt-in and
   tool-surface preconditions are unconfirmed for cekernel's execution
   contexts.

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

### Open questions (verify before exercising Decision 3)

- **Opt-in gate in non-interactive sessions**: the confirmed gate
  satisfiers are user wording and skill/slash-command instructions. Whether
  an **agent definition's** system-prompt instruction satisfies the gate in
  a `claude --bg --agent <name>` session — where no user utterance exists —
  is unverified.
- **Workflow tool on a subagent's tool surface**: the Reviewer (subagent at
  depth 1 per ADR-0012 Amendment 2) launching workflow agents puts those at
  depth 2. Nesting is supported (v2.1.172+), but whether the Workflow tool
  is exposed to subagents at all, and whether `agents/reviewer.md` `tools:`
  must list it, is unverified.

Both must be resolved (PoC or primary-source confirmation) in the first
implementation issue that wants to exercise Decision 3 — not assumed.
Tracked in `docs/claude-code-constraints.md` § Dynamic Workflows.

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

### Trade-offs

**Zero dependency vs. duplicated capability**: cekernel keeps its own
fan-out-free lifecycle machinery even though `/workflows` can express
superficially similar structures. The cost is that two orchestration
vocabularies coexist in the ecosystem; the gain is that a research-preview
API can change or disappear without touching cekernel. Given cekernel's
persistence-first mission, dependency-freedom wins until the preview
stabilizes (the Decision 4 revisit trigger).

**Permissiveness vs. predictability in rule 3**: allowing Workers/Reviewers
to run workflows internally makes their resource usage less predictable
(one Worker may fan out 16 subagents). The alternative — banning workflows
inside cekernel agents — would be simpler to reason about but would deny
single-task parallelism where it is genuinely the right tool. The opt-in
gate plus explicit skill instruction keeps the decision visible and
auditable.

## Follow-ups

- README: user-facing "cekernel vs `/workflows`" guide (one table, one
  paragraph).
- `agents/worker.md` / `agents/reviewer.md`: note that workflow use is
  permitted for single-task fan-out when a skill instructs it.
