# ADR-0021: Reviewer Subagent Contract

## Status

Accepted

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

### 1. The Reviewer stops using a platform-managed worktree (#602)

Drop `isolation: worktree`. The leak's cause is delegating the Reviewer's
worktree lifecycle to a platform trigger (`WorktreeRemove`) that does not fire
under `--bg`; dropping the platform-managed worktree removes that dependency,
and the leak with it.

The replacement mechanism is settled when implementing #602 (see Amendment 1).
The leading option creates **no** Reviewer worktree at all — the Reviewer reads
the **Worker's existing worktree** read-only, which is alive throughout the
review window (cleaned up only after merge or escalation —
`agents/orchestrator.md` Worktree Lifetime). The PR stays the source of truth:
verify the worktree `HEAD` matches the PR head, escalate on drift, and never
check out or modify (git forbids a second worktree on the same branch). With no
reviewer-specific worktree, nothing can leak.

### 2. The Reviewer's state lives in a state file (#627)

The Orchestrator writes `reviewer-<issue>.state` around the `Agent(reviewer)`
call: before invoking → `REVIEWING`; on return → `TERMINATED:<verdict>`
(`approved` / `rejected` / `escalated`). `orchctl ls`/`ps` enumerate
`reviewer-*.state` alongside `worker-*.state`. A subagent has no
`claude agents --json` liveness, so the state file is the single source of
truth for its status — the same model ADR-0020 adopted for held slots that
have no process-table liveness. The Reviewer's real liveness is bounded by
the Orchestrator's foreground block; if the Orchestrator dies mid-review the
state goes stale. Note this needs care in gc: today gc keys the worker sweep
on the record's *own* session-token liveness, which a subagent does not have,
so a `REVIEWING` record must instead be protected by the owning
**Orchestrator's** liveness. That is new gc logic, not a reuse of the worker
rule — see Open Questions.

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

Decision 1 removes the Reviewer's reliance on a platform trigger that
surprisingly does not fire under `--bg`; the Reviewer works within cekernel's
existing worktrees instead of a platform-managed throwaway.

### Platform Constraints

- **`--bg` vs interactive worktree lifecycle**: the leak (#602) exists because
  `WorktreeRemove` fires only interactively — an "Evolving" platform behavior.
  Dropping `isolation: worktree` removes the platform-managed worktree
  entirely, so if the platform later fires the trigger under `--bg` it has
  nothing to act on — no staleness risk either way.
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
response (take the Reviewer's mechanism off the platform's defaults). One
contract is clearer than three more entries on an already-long chain (Rule of
Clarity).

## Open Questions

Both are left for the Decision 2 implementation (#627).

### Does `reviewer-<issue>.state` count against `CEKERNEL_MAX_ORCH_CHILDREN`?

Introducing a Reviewer state file raises a slot-accounting question this ADR
does not settle. The child limit counts "workers + reviewers"
(ADR-0014; `agents/orchestrator.md:90`, `envs/README.md:13`). Reviewers did
consume a slot in the Amendment-1 era, when `spawn-reviewer.sh` wrapped
`spawn.sh` and passed through its child guard. As a foreground subagent the
Reviewer no longer spawns via `spawn.sh` — it blocks the Orchestrator (no new
Worker is spawned while it runs), yet it is still live alongside the background
Workers of *other* issues. So whether it should occupy a concurrency slot is
genuinely non-obvious:

- **Count it**: a live child consuming resources concurrently with other
  Workers; keeps the limit a true ceiling on concurrent children.
- **Do not count it**: it adds no new spawn pressure (the Orchestrator is
  blocked while it runs), so counting it needlessly shrinks effective Worker
  capacity during every review.

Resolve this explicitly, and align the slot-enumeration code with the choice.

### How does gc protect a live `reviewer-<issue>.state` from being reaped?

gc's worker sweep keys on the record's *own* session-token liveness plus a
NEW/READY timeout. A Reviewer subagent has no session token, so that rule would
reap a live `REVIEWING` record immediately. Protecting it requires new gc logic
keyed on the owning **Orchestrator's** liveness (the Orchestrator-metadata gc
path already reasons about Orchestrator liveness, but does not clean
`reviewer-*.state` today). Decide the exact mechanism when wiring
`reviewer-*.state` into gc.

*(Resolved by #678, 2026-07-12: the interim answer — exclude reviewer state
from gc entirely — leaked IPC session dirs forever, since a leftover
`reviewer-*.state` blocked `rmdir` (48 dirs observed). gc now sweeps
`reviewer-*.*` under the standard orphan rule, and the Orchestrator-liveness
check protects active reviewers exactly as anticipated here: when the
orchestrator session is alive or unverifiable, its non-TERMINATED reviewers
are registered as active before the sweep — never reap on doubt.)*

## Consequences

### Positive

- The Reviewer no longer depends on a platform-managed worktree; its state and
  verdict are cekernel-controlled — consistent with the Worker.
- The worktree leak is closed structurally, not swept; reviews become visible
  in `orchctl ls`/`ps`; the Orchestrator no longer reports a simulated
  approval or swallows a security warning.

### Negative

- The Orchestrator gains a small duty: write `reviewer-<issue>.state` around
  the `Agent(reviewer)` call. The leading worktree option (reuse the Worker's,
  settled in #602) adds no create/remove step and needs no `gc` insurance
  sweep.

### Trade-offs

- The state file can go stale if the Orchestrator dies mid-review. Accepted:
  staleness is bounded by and detected through the Orchestrator's own liveness,
  not a new mechanism — the same trade-off ADR-0020 already made for
  liveness-less records.

## Amendments

### Amendment 1 (2026-07-09): reuse the Worker's worktree

As accepted, Decision 1 named a concrete mechanism — a dedicated
`.worktrees/reviewer-<issue>/` that cekernel adds and removes, plus a `gc`
insurance sweep. During #602 implementation triage a simpler mechanism was
found that satisfies the same decision (drop `isolation: worktree`; take the
Reviewer's worktree off the platform's defaults): create **no** reviewer
worktree at all and read the Worker's existing worktree read-only, keeping the
PR as the source of truth (verify `HEAD` matches the PR head, escalate on
drift). With no reviewer worktree, the leak is impossible by construction and
the `gc` insurance sweep is unnecessary.

Feasibility was probed (2026-07-09): a non-isolated subagent reaches the
Worker's worktree, the PR-anchor check distinguishes a match from drift, and
on-disk reads match the PR diff. Decision 1 above is reworded to state the
principle and name this as the leading mechanism; the exact form is confirmed
when implementing #602, gated by the both-modes live check (CLAUDE.md).

### Amendment 2 (2026-07-11): Reviewer result handling (#646)

First production reviews (PRs #645/#647/#648) exposed three defects in
Decisions 2–3 — all rooted in the Orchestrator's handling of the Reviewer
result, not the Reviewer's execution model itself.

#### (α) External-Write false positive — authorization in Reviewer prompt

The auto-mode `[External System Writes]` security classifier flagged the
Reviewer's legitimate `gh api .../reviews` POST as an unauthorized external
write, intermittently (2/3 in production, 3/3 in controlled probes without
the fix). The classifier's clear condition states: "*the user must name the
PR being reviewed and authorize posting the review comment*". The
Orchestrator→Reviewer prompt named the PR (`Review PR #<pr>`) but did not
explicitly authorize the POST.

**Fix**: add `You are authorized to post a review comment on PR #<pr> in
<owner/repo> via gh api.` to the Orchestrator→Reviewer prompt template
(`agents/orchestrator.md`). Probed at clonable-eden/test-cekernel PR #118:
0/3 false-fire rate with the authorization text vs 3/3 without.

`reviewer.md` is unchanged — the Reviewer's responsibility to submit reviews
via `gh api` is unaffected. The authorization is an Orchestrator-side prompt
addition, consistent with the classifier's documented clear condition.

#### (β) Reviewer verdict protocol — canonical enum and validation

The same `approved` outcome was recorded as three different strings across
production runs: `approved` (Reviewer's actual verdict), `unverified`
(Orchestrator narration in #641), `escalated` (state file in #643/#644).
Neither `unverified` nor `escalated` is part of the Reviewer's return
contract (`approved / changes-requested / failed`); both were
Orchestrator-invented labels written to `reviewer-<issue>.state` without
validation. `reviewer_state_write` accepted any string, so the inconsistency
was silent (violating Rule of Repair).

**Fix**: `reviewer_state_write` now validates the detail field when state is
`TERMINATED` — only `approved`, `changes-requested`, and `failed` are
accepted; unknown values produce exit 1 with an error message. The
Orchestrator records the Reviewer's actual verdict, not a derived label.
Escalation is an Orchestrator *action* (desktop notification, runbook
comment), not a verdict *value*. `unverified` and `escalated` as verdict
strings are eliminated.

**Action matrix** (Orchestrator's response to Reviewer verdict × SECURITY
WARNING presence):

| Reviewer verdict | SECURITY WARNING | Orchestrator action |
|-----------------|-----------------|---------------------|
| `approved` | absent | merge (auto) or notify (manual) |
| `approved` | present | escalate |
| `changes-requested` | absent | Worker re-spawn |
| `changes-requested` | present | escalate |
| `failed` | N/A | escalate |
| no verdict / invalid | N/A | escalate |

#### (γ) Escalation preserves worktree and lock

The escalation path previously ran `cleanup-worktree.sh` + `issue_lock_release`,
destroying the worktree and releasing the lock. Escalation is a non-terminal
state (the issue returns to a human for disposition), yet the runtime signaled
completion: the worktree was gone (preventing `--resume` for
`changes-requested`), and the freed lock let the dispatcher re-acquire the
issue.

**Fix**: escalation no longer runs cleanup or lock release. The Orchestrator
posts a runbook comment on the issue with three action commands
(approve-and-merge, resume, reject) that the human executes. Cleanup happens
only at true terminal states (merged, or human-initiated rejection). With
(α) eliminating the `[External-Write]` false positive, escalation becomes a
rare-case path (genuine security concerns, Agent tool errors, retry limit
exhaustion), so the runbook approach satisfies Rule of Parsimony.

#### UNIX Philosophy Alignment

> Rule of Repair: "When you must fail, fail noisily and as soon as possible."

(β) makes `reviewer_state_write` reject unknown verdicts at write time
instead of silently accepting them. (γ) ensures escalation preserves the
evidence (worktree, lock) for human inspection.

> Rule of Least Surprise: "In interface design, always do the least
> surprising thing."

(α) aligns the prompt with the security classifier's documented clear
condition — the Reviewer is authorized to do what it was designed to do.
(β) eliminates surprising verdict label inconsistency.

> Rule of Parsimony: "Write a big program only when it is clear by
> demonstration that nothing else will do."

(γ) uses a runbook comment for rare-case escalation instead of building
automated rollback or disposition machinery.
