# ADR-0018: Platform Interface Contracts

## Status

Accepted

## Context

The first self-hosted v2 runs (2026-07-07) produced a cluster of small bugs
with an identical shape — an **implicit interface consumed by many callers,
each with its own interpretation**:

- #581: `agents --json` split live sessions into `status:"busy"` +
  `state:"working"`; liveness checks reading `state` declared every healthy
  Worker crashed.
- #591: the #584 fix (`.status // .state`) then broke *terminal* detection,
  because `done` sessions carry `status:"idle"` — liveness and terminality
  were conflated into one expression.
- #589: the on-demand daemon hands sessions the env of whichever client
  auto-started it — nobody had specified whose env a session is guaranteed
  to receive.
- #562 (earlier): `spawn.sh` and the Worker had no contract about who
  communicates the PR base branch.

Today **10 files call `claude agents --json` directly**. `claude-bg.sh`
exists as a primitives layer but is bypassed by 9 consumers, and its own
predicate contains the #591 conflation. Platform drift therefore breaks an
unbounded set of call sites, and each fix is a scattershot patch.

The root cause is not the Evolving platform surface — that is a known tax
(claude-code-constraints.md) — but that cekernel has no **single owner per
boundary** stating what is guaranteed, to whom, and where drift is absorbed.

## Decision

### 1. `claude-bg.sh` is the sole owner of the claude CLI surface

All invocation and parsing of `claude --bg` spawn output, `claude agents
--json`, `claude stop`, and daemon queries live in `scripts/shared/
claude-bg.sh`. **Raw platform JSON never crosses the module boundary.**

**Layer hierarchy** (ownership is meaningless if undeclared):

```
claude-bg.sh     — CLI surface: the ONLY parser of platform output
  ↑ consumed by
bg-session.sh    — lifecycle core (spawn/supervise/terminate), predicates only
  ↑ consumed by
backends / watch / orchctl / wrapper / registry / gc / issue-lock
```

`bg-session.sh` and every other consumer use the predicates below; none
of them may parse `agents --json` output themselves.

The module reports observations in **three dimensions, kept distinct** —
session verdict, and two failure kinds that are NOT verdicts:

| Report | Meaning | Backed by (v2.1.201 matrix) |
|--------|---------|------------------------------|
| `alive` | session running or waiting | `status` ∈ {`busy`, `blocked`} |
| `blocked` | waiting on a permission dialog | `status` == `blocked` |
| `terminal` (`done`/`stopped`) | session finished / was stopped | `state` ∈ {`done`, `stopped`} |
| `not-listed` | no session matches the token | absent from `agents --json` |
| `query-failed` | the platform query itself failed | CLI error / daemon unreachable |
| `unknown-value` | (status, state) pair not in the matrix | schema drift detected |

Liveness reads `status`; terminality reads `state`. **The predicates
guarantee honest reporting, not interpretation**: `not-listed`,
`query-failed`, and `unknown-value` are returned distinctly (distinct exit
codes / echoed tokens, plus a stderr warning for `unknown-value`) and are
never coerced into alive or dead. Coercing an unknown status to "dead" is
exactly how #581 killed healthy Workers; this contract makes that class of
bug impossible *inside* the layer.

**Degradation policy belongs to each consumer** (Rule of Separation —
policy stays out of the mechanism): issue-lock treats `query-failed` as
alive (never steal a lock on doubt — its existing, correct behavior);
watch retries then escalates; gc refuses to reap. The ADR fixes the
vocabulary, not the reactions.

### Observed (status, state) matrix — v2.1.201, 2026-07-07

| `status` | `state` | Verdict |
|----------|---------|---------|
| `busy` | `working` | alive |
| `blocked` | `working` | alive + blocked |
| `idle` | `done` | terminal (`done`) |
| `idle` (or absent) | `stopped` | terminal (`stopped`) |
| — session absent — | | not-listed |
| any combination not above | | unknown-value |

This table is the contract. It is mirrored in the `claude-bg.sh` header,
`docs/claude-code-constraints.md` § Background Agent Sessions, and
`mock-claude.bash`; the ADR-0017 staleness rule couples all three.

### 2. mock-claude is the executable specification

`tests/helpers/mock-claude.bash` emits the same (status, state) matrix and
is the contract's test double (staleness coupling per ADR-0017: a PR that
updates the constraints-doc matrix MUST update the mock in the same PR).
Contract tests exercise the predicates against every matrix row **and**
the three non-verdict reports: a not-listed token, a failing CLI, and an
out-of-matrix (status, state) pair each produce their distinct report —
never a coerced alive/dead (Rule of Repair: the layer's job is to make
drift *visible*, not to guess).

### 3. Session env is guaranteed by the spawner, not the daemon

The daemon's inherited environment is declared **unspecified** — no
cekernel code may rely on it (#589). Every spawn injects its session's
`CEKERNEL_*` values explicitly (Workers: sourcing the worktree's
`.cekernel-env` per Bash call — existing mechanism, now normative;
Orchestrators: exported by `spawn-orchestrator.sh` at exec).

### 4. The task file is the spawn → Worker interface

Everything a Worker must know that is not in the issue itself (base
branch, resume reason, env profile) travels as a named section of
`.cekernel-task.md` (`## Base Branch:` etc., #567). Prompt text is
narrative; the task file is contract. New spawn-time information extends
the task file, not the prompt.

### 5. Boundary ownership table

| Boundary | Owner (guarantor) | Contract artifact |
|----------|-------------------|-------------------|
| cekernel ↔ claude CLI | `claude-bg.sh` | predicate semantics + matrix header |
| spawn → Worker | `spawn.sh` (writer), task file (medium) | named task-file sections |
| daemon → session env | the spawner | explicit injection; daemon env unspecified |
| Orchestrator ↔ Reviewer | reviewer return contract | final-line token (ADR-0012 A2) |
| Worker/Reviewer → Orchestrator | FIFO status line + state file | ADR-0007 (unchanged; see #586 for future reduction) |

Review criterion (CLAUDE.md follow-up): introducing a direct `claude`
CLI parse outside `claude-bg.sh`, or a new implicit cross-boundary
assumption, is grounds for changes-requested.

## Alternatives Considered

### Patch each consumer as drift appears

Status quo. Rejected: #581 → #584 → #591 demonstrated the failure mode —
each patch is itself an uncoordinated interpretation, and the platform
surface is Confidence: Evolving, so drift will recur.

### Pin the claude CLI version

Freeze the platform to avoid drift. Rejected: cekernel's value is riding
the standard primitives (ADR-0016); pinning trades small recurring bugs
for growing divergence. A minimum version is already pinned; an upper pin
is not maintainable.

## Consequences

### Positive

- Platform drift has a blast radius of one module + one test file.
- "What does each side guarantee" is answerable by reading one table.
- Predicates make call sites express intent (`bg_is_alive`) instead of
  schema trivia — Clarity over cleverness.

### Negative

- One more indirection layer; contributors must learn "never parse
  agents --json yourself." Mitigated by the review criterion and the
  predicates being easier than raw jq.
- The matrix is still an observation of an Evolving surface; contracts
  reduce the cost of drift, they do not prevent it.

## Follow-ups

- Implementation issue: migrate the 9 bypassing consumers, fix #591
  (terminal reads `state`) and #589 (env injection normative) inside the
  new contract. Fold in #573 item 2 (transient-error vs not-listed
  distinction) — it is this ADR's failure semantics.
- Implementation verification: whether `claude agents --json` resurrects
  the on-demand daemon as a side effect — predicates should be
  side-effect-free observers, or the effect must be documented in the
  constraints doc.
- CLAUDE.md: add the review criterion.

## Amendment 1 (2026-07-19): `blocked` verdict split — evidence-based via `waitingFor` (#673)

### Context

The `blocked` verdict conflates two realities that live probing
(2026-07-18/19, claude v2.1.214) proved distinguishable:

| Reality | Observed shape | `waitingFor` |
|---------|----------------|--------------|
| **Genuine permission stall** (probe, `--permission-mode default`) | `waiting/blocked` | `"permission prompt"` — present |
| **Phantom blocked**: session completed normally, transcript shows final summary | `idle/blocked` | field absent |

The phantom case first hit production 2026-07-10/11 (three orchestrators,
slot exhaustion) and was reproduced on 2026-07-19: the orchestrator
processing #681 itself finished cleanly yet reported `idle/blocked` for
13+ minutes, holding a concurrency slot (session `14b5ebde`, raw record
and transcript preserved in #673). Upstream docs define completion as
`done`/`failed` — the phantom is a CLI defect, but it recurs on the
current CLI, so cekernel must absorb it (this ADR's charter: drift is
absorbed at the boundary, not denied).

Today's consumer behavior is mutually inconsistent (audited in #673):
`orchctl count` treats `blocked` as occupying, `orchctl gc` refuses to
reap it, yet `claude_bg_wait_terminal` treats it as terminal. A phantom
therefore occupies a slot forever that nothing may reclaim.

**Version fragility**: `idle/blocked` meant a *genuine* stall on v2.1.202
and means *phantom* on v2.1.214. Any split keyed on `(status, state)`
alone inherits this instability; `waitingFor` presence is the only
observed signal that tracks the semantic difference across versions.

### Decision

1. **Ingest `waitingFor` as a third verdict input** in `claude-bg.sh`.
   The matrix gains a `waitingFor` column.
2. **Split the verdict**:
   - `state: blocked` + `waitingFor` present → **`blocked`** (genuine
     stall; unchanged semantics)
   - `state: blocked` + `waitingFor` absent → **`stale-blocked`** (new
     token, exit 0): "the CLI says blocked but presents no evidence of
     waiting"
   - Legacy pre-`waitingFor` shapes (`blocked/working`, `blocked/-`,
     `-/blocked`) → `blocked` (conservative: absence of the field on a
     CLI that never emitted it is not evidence)
3. **`stale-blocked` is a report, not an interpretation** (Rule of
   Repair, the #581 lesson): the mechanism never coerces it to `done`.
   Degradation policy stays at each call site (Rule of Separation):
   - `orchctl count` — `stale-blocked` still counts as occupying (a slot
     frees only when its session is actually gone)
   - `orchctl gc` — may reap a `stale-blocked` orchestrator **only when**
     all child workers are `TERMINATED` **and** its IPC dir has been
     quiescent for a grace period (`CEKERNEL_GC_STALE_BLOCKED_GRACE`,
     default 600s). Any guard failing → keep, as today
   - `claude_bg_wait_terminal` — returns `blocked` and `stale-blocked`
     as distinct terminal outcomes
   - Boolean projection (`claude_bg_token_alive`) — `stale-blocked`
     projects to alive (conservative). The gc triple-guard path is the
     ONLY consumer permitted to treat it as reapable; every other
     predicate consumer sees an occupied session. Leaving this
     unspecified would invite per-consumer reinterpretation — the
     failure shape this ADR exists to prevent
   - `watch.sh` / Orchestrator — genuine `blocked` keeps the current
     pipeline unchanged: `watch.sh` writes `TERMINATED:blocked` and
     surfaces the `blocked` result; the **Orchestrator** then stops the
     session and cleans up (agents/orchestrator.md blocked handler).
     `stale-blocked` defers to the Worker's own state file and never
     fabricates a `TERMINATED:blocked` record
4. **Staleness coupling extends to the new column**: claude-bg.sh
   header, claude-code-constraints.md matrix, and mock-claude.bash
   update together; the mock emits `waitingFor` for the genuine-stall
   row and omits it for the phantom row.

### UNIX Philosophy Alignment

> Rule of Repair: "When you must fail, fail noisily and as soon as
> possible."

`stale-blocked` surfaces the platform defect as a distinct, visible
token instead of silently occupying a slot (status quo) or silently
coercing to `done` (the #581 failure class).

> Rule of Separation: "Separate policy from mechanism."

The mechanism reports evidence (`waitingFor` seen / not seen); what to
*do* about a phantom — count it, reap it, how long to wait — remains
explicit per consumer.

> Rule of Representation: "Fold knowledge into data so program logic can
> be stupid and robust."

The version-fragility problem is solved by adding one observed *data*
column, not by version-sniffing logic.

### Platform Constraints

The `agents --json` surface remains **Confidence: Evolving**.
`waitingFor` is observed on v2.1.214 only; the phantom's shape
(`idle/blocked`) collides with a historical genuine shape. Staleness
risk: re-probe the matrix on CLI upgrades (the reproduction recipe is in
#681/#673). Polling remains the only observation channel — hence a
grace-period heuristic, not an event.

### Alternatives Considered

- **Discriminate by `status` (`waiting` vs `idle`)**: rejected —
  `idle/blocked` was genuine on v2.1.202; version-fragile (see Context).
- **Coerce `waitingFor`-absent blocked to `done`**: rejected — #581
  class. Transcript-level completion evidence is unavailable to the
  mechanism layer; gc's guarded reap achieves the effect without lying
  about observations.
- **Wait for the upstream fix**: rejected — falsified by the 2026-07-19
  reproduction on current CLI; the defensive design is sound even if
  upstream later fixes the phantom (the `stale-blocked` path simply
  stops firing).
- **Nudge remediation** (send a message to the phantom session so a
  fresh end-of-turn rewrites the state): unverified platform behavior —
  recorded as a follow-up experiment, not a decision.

### Consequences

**Positive**: phantom slot leaks become self-healing (gc reaps under
triple guard); both #673 failure directions are covered by live evidence
(probe session `47455a37` for genuine, session `14b5ebde` for phantom);
vocabulary stays honest.

**Negative**: consumers gain one more verdict case. The residual
misclassification risk is drift-shaped, not design-shaped: a genuine
stall is reaped only if the CLI stops emitting `waitingFor` for real
permission prompts (schema drift), misclassifying it as `stale-blocked`
— and even then the triple guard (workers all TERMINATED + IPC
quiescent + grace) must also pass before a reap. By design, a genuine
stall with `waitingFor` present maps to `blocked` and is never reaped.

**Follow-ups**: implementation issue for the split + consumer policies
(worker-scale granularity), including the `CEKERNEL_GC_STALE_BLOCKED_GRACE`
entry in the `envs/README.md` catalog; nudge experiment on next phantom
occurrence; matrix re-probe on CLI upgrade.
