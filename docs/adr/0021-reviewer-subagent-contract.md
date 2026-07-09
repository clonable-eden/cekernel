# ADR-0021: Reviewer Subagent Contract

## Status

Proposed

Supersedes ADR-0012 Amendments 1, 2, and 5 (the Reviewer *mechanism*).
ADR-0012's core decision — separating review and merge from Worker
responsibilities — stands. This ADR is the design basis for #602, #627,
and #628.

## Context

ADR-0012 separated the Reviewer from the Worker. How the Reviewer is *run*
then changed repeatedly:

- **Amendment 1 (2026-03)**: independent process via `spawn-reviewer.sh` +
  FIFO notification, because deeply nested subagents were unreliable then.
- **Amendment 2 (2026-07)**: nested subagents became supported (fixed depth
  5), so the Reviewer moved back to an Orchestrator subagent with
  `isolation: worktree`.
- **Amendment 5 (2026-07-07)**: the subagent grant was made namespace-agnostic
  (#600).

The subagent move (Amendment 2) is sound but left three defects — all
consequences of the same shift, all invisible under local self-hosting but
real under `claude --bg`:

1. **Worktree leak (#602)**: platform-managed `isolation: worktree`
   auto-cleanup fires only in interactive runs. cekernel's production mode is
   `claude --bg`, where the `WorktreeRemove` trigger does not fire, so
   `.claude/worktrees/agent-*` accumulates (untracked in `git status`).
   Verified 2026-07-08.
2. **State invisibility (#627)**: a subagent is not a background session — it
   never appears in `claude agents --json` and writes no handle or state file.
   `orchctl ps` builds its managed rows from `handle-<issue>.<type>` files
   joined to `claude agents --json` liveness; `orchctl ls`/`gc` enumerate
   `worker-*.state`. The Reviewer writes neither a handle nor a
   `reviewer-*.state`, so it appears in no row of either. Operators cannot see
   that a review is in progress.
3. **Simulated approval (#628)**: a single GitHub identity cannot `APPROVE`
   its own PR, so the Reviewer writes `APPROVE` into a `COMMENT` body to
   simulate it. This trips the auto-mode `[Self-Approval]` guard; the
   Orchestrator then ignores the warning and reports "approved" with no
   caveat.

Three more amendments would deepen an already-long chain. This ADR restates
the Reviewer mechanism as one coherent contract.

## Decision

The Reviewer remains an Orchestrator subagent. Three rules define its
contract.

### 1. cekernel owns the Reviewer worktree (#602)

Drop `isolation: worktree`. cekernel creates and removes the worktree itself
— `.worktrees/reviewer-<issue>/` via `git worktree add`/`remove`, on the same
`cleanup-worktree.sh` lifecycle that already governs Worker worktrees. The
leak's cause is delegating worktree lifecycle to a platform trigger that does
not fire under `--bg`; owning it removes that dependency. A small
`orchctl gc` sweep of stray `reviewer-*` worktrees remains as insurance
against abnormal termination.

### 2. The Reviewer's state lives in a state file (#627)

The Orchestrator writes `reviewer-<issue>.state` around the `Agent(reviewer)`
call: before invoking → `REVIEWING`; on return → `TERMINATED:<verdict>`
(`approved` / `rejected` / `escalated`). `orchctl ls`/`ps` enumerate
`reviewer-*.state` alongside `worker-*.state`. A subagent has no
`claude agents --json` liveness, so the state file is the single source of
truth for its status — the same model ADR-0020 adopted for held slots that
have no process-table liveness. The Reviewer's real liveness is bounded by
the Orchestrator's foreground block; if the Orchestrator dies mid-review the
state goes stale, which is detected via the Orchestrator's own liveness
(existing gc / health-check paths), not the Reviewer's.

### 3. Verdict is out-of-band; no approval word in the GitHub body (#628)

- The Reviewer posts a **neutral COMMENT** on its own PR; it never writes
  `APPROVE` (or equivalent) in the body.
- The verdict travels **out-of-band** — the Reviewer's final output line,
  consumed by the Orchestrator. It does not depend on GitHub review state.
- If a subagent result carries a SECURITY WARNING, the Orchestrator **does not
  auto-advance**; it surfaces the warning in its summary and treats the
  verdict as unverified (Rule of Repair).

This separates the *judgment channel* (out-of-band line) from the *GitHub
artifact* (a neutral comment), so the Reviewer stops simulating an approval it
cannot legitimately make and the Orchestrator stops swallowing a security
signal.

### UNIX Philosophy Alignment

> Rule of Separation: "Separate policy from mechanism; separate interfaces
> from engines."

Decision 3 separates the verdict (policy signal) from the GitHub comment
(artifact). Conflating them — encoding the approval decision in comment text —
is what produced the fake-approval smell.

> Rule of Representation: "Fold knowledge into data so program logic can be
> stupid and robust."

Decision 2 folds the Reviewer's status into a state file instead of inferring
it from a liveness query that returns nothing for subagents. `orchctl` logic
stays simple: enumerate state files.

> Rule of Repair: "When you must fail, fail noisily and as soon as possible."

Decision 3 stops the Orchestrator swallowing a SECURITY WARNING. Decision 1
stops a silent worktree leak — an accumulation that fails quietly.

> Rule of Least Surprise: "In interface design, always do the least surprising
> thing."

Decision 1 makes the Reviewer worktree behave like the Worker's — cekernel
owned and cleaned — instead of relying on a platform trigger that surprisingly
does not fire under `--bg`.

### Platform Constraints

- **`--bg` vs interactive worktree lifecycle**: the leak (#602) exists because
  `WorktreeRemove` fires only interactively — an "Evolving" platform behavior.
  If the platform later fires it under `--bg`, Decision 1 is still safe
  (removing an already-removed worktree is idempotent), so there is no
  staleness risk.
- **Subagent has no session liveness**: a subagent does not appear in
  `claude agents --json`; Decision 2 follows directly — state file, not
  liveness query.
- **auto-mode security classifier (#595)**: the `[Self-Approval]` and
  external-write warnings are auto-mode behavior. Decision 3 is designed to
  not trip Self-Approval (neutral comment) and to not ignore the warnings that
  remain.
- **Both-modes feasibility (CLAUDE.md)**: this touches agent spawn, worktree,
  and grants — it MUST be dogfooded in a foreign repo via `--plugin-dir`, not
  local-only. Amendment 2's own history (#600) is the cautionary precedent.

## Alternatives Considered

### Alternative: gc-only cleanup (keep `isolation: worktree`)

Reap the leftover `agent-*` dirs with `orchctl gc` and keep the
platform-managed worktree. Rejected: it keeps a broken platform dependency and
needs fragile per-worktree liveness to avoid reaping another Orchestrator's
in-flight reviewer worktree. It treats the symptom, not the cause (Rule of
Repair).

### Alternative: revert to spawn + FIFO (Amendment 1)

Make the Reviewer an independent process again. Rejected: it discards
Amendment 2's gains (no `spawn-reviewer.sh`, no FIFO, synchronous return
contract, #521 truncation fix) to solve only the worktree leak.

### Alternative: three separate amendments to ADR-0012

Rejected: the three defects share one root (the subagent shift) and one design
response (cekernel-owned mechanism). One contract is clearer than three more
entries on an already-long chain (Rule of Clarity).

## Consequences

### Positive

- Reviewer worktree, state, and verdict are all cekernel-owned and consistent
  — the same ownership model as the Worker.
- The worktree leak is closed structurally, not swept; reviews become visible
  in `orchctl ls`/`ps`; the Orchestrator no longer reports a simulated
  approval or swallows a security warning.

### Negative

- The Orchestrator gains two small duties: create/remove the Reviewer
  worktree, and write `reviewer-<issue>.state` around the call. A minimal
  `gc` insurance sweep remains — not zero mechanism.

### Trade-offs

- The state file can go stale if the Orchestrator dies mid-review. Accepted:
  staleness is bounded by and detected through the Orchestrator's own liveness,
  not a new mechanism — the same trade-off ADR-0020 already made for
  liveness-less records.
