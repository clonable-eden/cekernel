# ADR-0020: Retire the Completion FIFO — Two-Source Detection

## Status

Proposed

## Context

Worker completion is detected through three sources (ADR-0016 records the
triple-path): the **FIFO** (`${CEKERNEL_IPC_DIR}/worker-<issue>`, push,
sub-second), the **state file** (`worker-<issue>.state`, semantic record,
poll fallback), and **`claude agents --json`** (liveness verdicts via
`claude-bg.sh`, ADR-0018). The FIFO predates the v2 platform: under v1's
`-p` fork model there was no supervisor, so parent-child completion
signaling had to be hand-built. ADR-0016 gave cekernel a kernel-grade
process roster; ADR-0012 Amendment 2 already moved the Reviewer off the
FIFO (subagent return value). The FIFO's remaining users are the Worker
completion path and, less visibly, the process tooling that enumerates
Workers by iterating pipes (fact 6) and the reaper that removes them
(fact 7).

Investigation (#586, 2026-07-08) established five facts; architecture
review of this ADR (PR #610, 2026-07-08, six passes) added four more:

1. **Degradation is already implemented.** `notify-complete.sh` writes the
   state file *first* and exits 0 when the FIFO is absent; `watch.sh`
   falls back to state polling with a `FIFO_MISSING` log. The FIFO is
   de facto optional today.
2. **The FIFO's load-bearing role is not notification.** `spawn.sh`'s
   concurrency guard counts named pipes (`active_worker_count()`), and
   `watch.sh`'s `rm -f "$fifo"` on read is what frees a slot — the FIFO
   is the **concurrency-slot token** (ADR-0012 § Concurrency Slot
   Behavior).
3. **The fallback path loses payload.** The state file carries the result
   (`TERMINATED:<ts>:ci-passed`) but not the notify `detail` (PR number);
   state-fallback results substitute `detected-via-state-fallback`.
4. **The FIFO has a verified writer-hang hazard.** A write to a pipe with
   no reader blocks forever (measured). If the Orchestrator dies leaving
   the pipe file (SIGKILL — normal exits remove it), the Worker's
   `notify-complete.sh` hangs at its final step.
5. **Push latency is not load-bearing.** FIFO push is sub-second; state
   polling detects within `CEKERNEL_POLL_INTERVAL` (30s). Worker
   lifecycles are minutes to hours; the relative cost of polling latency
   is <1%, and the state read is a local-filesystem operation cheap
   enough to poll faster.
6. **The FIFO is also the roster key for process tooling.** `orchctl`
   `list`/`status`/`gc`, `process-status.sh`, and `health-check.sh`
   discover Workers by iterating pipes (`for fifo in ... worker-*;
   [[ -p ]]`). This is a second hidden coupling of the same kind as
   fact 2 — the "notification channel" doubles as the process-table
   entry. `health-check.sh` couples deepest: its zombie *definition* is
   FIFO-based ("FIFO exists but process dead"; "no active FIFO =
   completed"), not just its discovery loop. (Elapsed time already
   comes from the `.spawned` file, not the pipe; enumeration and the
   zombie predicate are what's coupled.)
7. **The FIFO has a third slot-release site: the reaper.**
   `cleanup-worktree.sh` removes the pipe expressly so that
   "concurrency slots do not leak" (its header comment) and deletes
   the state file with it. It is the lifecycle's reap step, invoked by
   the Orchestrator after handling a result — and the terminus of the
   documented timeout protocol (`send-signal TERM` → grace →
   `cleanup-worktree.sh --force`, orchestrator.md). Any slot-accounting
   migration must give the reaper explicit semantics, or the timeout
   path frees slots by erasing history.
8. **The reap step erases the lifecycle log today.**
   `cleanup-worktree.sh` deletes `logs/worker-<issue>.log` along with
   the other IPC files, and `orchctl gc`'s orphan sweep removes logs
   for issues with no active pipe. Any record-beats-erasure claim on
   the reap path must change log retention explicitly — it cannot be
   assumed (a claim of exactly this kind survived three review passes
   of this ADR because it was coherent in-document and false in-repo).
9. **gc's orphan sweep reaps by pipe absence — a fourth reap site.**
   `orchctl gc` first classifies each pipe via `_gc_is_stale_fifo`
   (liveness verified through the handle with ADR-0018
   refuse-on-doubt: `query-failed`/`unknown-value` count as alive;
   stale means `TERMINATED` with no live handle, a verifiably dead
   handle, or a handle-less entry that is either `NEW`/`READY` past
   its spawn grace or in a running-family state — running without a
   handle is abnormal by definition), removes
   stale pipes, then `_gc_clean_orphan_files` deletes **every**
   `worker-*.*` companion file — the state file included — for any
   issue with no surviving pipe. Under state-based slot accounting,
   deleting a non-`TERMINATED` state file *frees the slot*: if
   `watch.sh` kept mechanically removing the pipe on unverified exits,
   a gc run would hand back exactly the held slot that Decision 2
   refuses to free — the over-spawn side door, opened by an operator
   sweep (found in the fifth review pass).

The deeper context is the project's standing: the platform is absorbing
agent-infrastructure concerns release by release, and cekernel is a
**transitional artifact by design** — its mechanisms are scaffolding to be
removed as the platform provides them natively (owner position,
2026-07-08). In OS terms: v1 had no kernel, so a hand-rolled pipe was
honest IPC; v2 has a kernel, and a real UNIX parent learns of a child's
exit from `wait()`/`SIGCHLD` — kernel accounting — not from a pipe the
child writes to before dying (a child that crashes writes nothing, which
is exactly why the third source exists). Counting pipes to limit
concurrency has no OS analog at all; the real thing is kernel process
accounting. The OS analogy, examined closely, argues *for* retirement.

## Decision

Retire the FIFO in 2.1. Completion detection becomes **two sources with
distinct axes**: the state file is the semantic record (what happened);
`claude agents --json` is liveness (is it still running). Concretely:

1. **State format carries the full payload.** `notify-complete.sh` writes
   `TERMINATED:<ts>:<result>:<detail>` (the format already permits colons
   in the detail field). `watch.sh`'s `build_result_from_state` splits
   result and detail, eliminating the fallback payload gap.
2. **Slot accounting moves to state files.** `active_worker_count()`
   counts `worker-*.state` files whose state is not `TERMINATED`. On the
   normal path a slot frees the moment `notify-complete.sh` writes
   `TERMINATED` — the same instant the FIFO removal frees it today,
   preserving ADR-0012's slot semantics (slot free during review,
   worktree retained). The reject → re-spawn cycle holds with no code
   change: `spawn.sh` writes `NEW` unconditionally, including under
   `--resume`, so a re-spawned Worker re-consumes a slot exactly as a
   fresh FIFO does today.

   **Abnormal paths write the exit record where the verdict is
   verified.** Today `watch.sh` frees the slot mechanically (`rm -f
   "$fifo"`) on *every* exit path, including unverified ones. The
   state model makes this decision explicit, per exit class:

   | `watch.sh` exit | Verdict quality | State write | Slot |
   |---|---|---|---|
   | completion (state read) | verified | already `TERMINATED` | frees |
   | crashed (`done`/`stopped`/`not-listed`/`missing`) | verified | `TERMINATED:<ts>:crashed:<detail>` | frees |
   | blocked | verified | `TERMINATED:<ts>:blocked:<detail>` | frees |
   | timeout | **unverified** | none | held |
   | query-escalated | **unverified** | none | held |

   Holding the slot on unverified exits is a deliberate behavior change
   from the FIFO model (which freed the slot even when "worker may
   still be running"): on doubt, refuse to free — over-holding degrades
   throughput; over-freeing over-spawns past `MAX_ORCH_CHILDREN`. This
   is the same degradation posture as `orchctl gc`'s "refuse to reap on
   doubt" (ADR-0018).

   **The held slot must survive `orchctl gc` — but not by retaining
   the pipe.** The pipe is the key that protects an issue's companion
   files from gc's orphan sweep (fact 9): with `watch.sh` removing it
   mechanically on unverified exits, a gc run would delete the held
   state file and free the slot with no exit record. Retaining the
   pipe on those exits looks like the symmetric fix (hold-on-doubt
   for both tokens) but reintroduces fact 4's hazard on the most
   natural doubt-resolution path: `watch.sh` has exited, so the pipe
   has no reader, yet it still exists — a Worker that later completes
   (the very "may still be running" case the hold exists for) passes
   `notify-complete.sh`'s missing-FIFO check and blocks forever on
   the write-open (found in the sixth review pass). Instead, the
   orphan sweep's **protection key** changes in Phase 1, ahead of the
   rest of gc's migration: a non-`TERMINATED` state file marks the
   issue active regardless of pipe presence. Pipe removal on exit
   stays exactly as today — which also keeps `notify-complete.sh` on
   its exit-0 fallback (fact 1), never the blocking write.
   Doubt is resolved by the existing operator paths,
   which already write the exit record: `orchctl recover`
   (`TERMINATED … crashed:detected-by-recover`) and `orchctl kill`
   (`TERMINATED … killed`). `orchctl gc`'s reap action likewise becomes
   a `TERMINATED … crashed:detected-by-gc` write instead of a pipe
   removal — an exit record beats erased history (Rule of
   Representation).

   The third resolver is the Orchestrator's own timeout protocol,
   which ends in `cleanup-worktree.sh --force` (fact 7). In the state
   model `cleanup-worktree.sh` is the **reap**: deleting the state
   file retires the roster entry and frees the slot, exactly as
   `wait()` consumes a zombie's process-table entry. Reaping a
   `TERMINATED` entry needs no further record — the exit was already
   written and consumed. Reaping a non-`TERMINATED` entry (`--force`
   on a hung Worker) appends the exit event to the lifecycle log
   (`logs/worker-<issue>.log`) before deletion. This requires a second
   behavior change (fact 8): today `cleanup-worktree.sh` deletes that
   log with the rest of cleanup, which would erase the record in the
   same breath — Phase 1 makes cleanup **retain** the log. Its terminal
   collector is `orchctl gc`'s orphan sweep: the record survives the
   automated lifecycle and is erased only by an explicit operator
   sweep. With both changes, record-beats-erasure holds on the reap
   path too: the process-table entry goes, the accounting stays.

   One table row is asymmetric by design: `blocked` records a session
   that is still *alive* (stalled on a permission dialog) as
   `TERMINATED` — terminal **by policy**, because nobody approves a
   dialog in a headless run (ADR-0016). Until cleanup stops the
   session (`cleanup-worktree.sh` kills the Worker via the backend),
   the exit record deliberately leads the process table, and Decision
   4's zombie predicate cannot flag the state (it is its inverse).
   The pairing is therefore normative: a `blocked` exit record is
   always followed by session stop in the same handling step.
3. **Polling splits by cost.** `watch.sh` polls the state file every
   `CEKERNEL_STATE_POLL_INTERVAL` (default 5s, local fs, negligible) and
   queries the backend verdict every `CEKERNEL_POLL_INTERVAL` (default
   30s, unchanged — `agents --json` spawns a process). Completion
   latency: sub-second → ≤5s.
4. **Roster enumeration moves to state files.** All pipe-iteration
   consumers (fact 6) — `orchctl list`/`status`/`gc`,
   `process-status.sh`, `health-check.sh` — switch to enumerating
   `worker-*.state` files via one shared helper in `worker-state.sh`
   (Rule of Modularity: one enumeration primitive, five consumers).
   The helper takes the IPC directory as an argument (defaulting to
   the session's own): four consumers are session-scoped, but
   `orchctl gc` sweeps every session directory under the IPC base.
   Enumeration semantics: the helper lists all state files with their
   states; consumers filter to non-`TERMINATED` entries. That
   reproduces today's pipe semantics (a pipe exists only while a
   Worker is active), so `worker-*.state` files persisting after
   `TERMINATED` do not leak completed Workers into `orchctl list`.
   For four consumers only the discovery key changes.
   `health-check.sh` is a redesign, not a key swap: its zombie
   predicate is FIFO-defined (fact 6) and is redefined on the state
   model as **non-`TERMINATED` state + dead backend verdict** — which
   is exactly Decision 2's held slot, so a zombie flag now points at
   the same doubt that `orchctl recover` resolves.
5. **Deletions.** `mkfifo` leaves `spawn.sh`; the FIFO branch leaves
   `watch.sh`; the FIFO write leaves `notify-complete.sh`; pipe
   iteration leaves `orchctl`, `process-status.sh`, and
   `health-check.sh`; the pipe removal (and its "slots do not leak"
   rationale) leaves `cleanup-worktree.sh`; the writer-hang hazard
   ceases to exist.
   `spawn.sh`'s stdout contract ("Output: FIFO path (stdout last
   line)", echoed by the `spawn-worker.sh` wrapper header) goes with
   Phase 3 — nothing captures the path today (`watch.sh` takes issue
   numbers), so the last-line output is simply dropped, not replaced.
   `README.md`'s OS-concept table re-maps two rows and drops one:
   completion = process table + exit record (`agents --json` + state
   file), not pipes; semaphore = non-`TERMINATED` state count, not
   FIFO count; the "IPC pipe" row is removed outright — after
   retirement cekernel contains no named pipe for the row to describe
   (the "Trigger: Event-driven (FIFO, …)" line and the
   directory-tree comments on `spawn.sh`/`watch.sh` update likewise).
   `agents/orchestrator.md`'s FIFO-premised prose (the
   completion-mechanism description and "Worker FIFO events buffer
   during the block") updates with Phases 3–4, and
   `skills/references/postmortem-patterns.md`'s "FIFO corruption or
   missing" detection pattern is pruned with them (along with the
   neighboring IPC-directory pattern's "FIFO-related errors" clause)
   — a post-mortem pattern for a retired mechanism only misdirects
   diagnosis.

Phasing (each phase lands and reverts separately; the order below is
load-bearing, not editorial):

- **Phase 1** = state detail + `watch.sh` terminal-state writes + slot
  migration (plus the `envs/README.md` catalog entries for
  `CEKERNEL_STATE_POLL_INTERVAL` and the currently uncataloged
  `CEKERNEL_POLL_INTERVAL`). These land **together**: once
  counting is state-based, a crashed Worker whose exit record nobody
  writes leaks its slot — the terminal-state writes are the
  slot-release mechanism, not an optimization. Phase 1 also carries
  the orphan-sweep protection-key change (Decision 2, fact 9: a
  non-`TERMINATED` state file marks the issue active, pulled ahead
  of the rest of gc's migration) and both reaper changes
  (Decision 2, fact 8): log-before-delete for `--force` on a
  non-`TERMINATED` state, and log retention (the
  `rm -f logs/worker-<issue>.log` leaves `cleanup-worktree.sh`).
  Slot release via state-file deletion itself needs no change.
- **Phase 2** = roster enumeration migration (Decision 4), including
  `orchctl gc`'s reap change (pipe removal → `TERMINATED` write,
  Decision 2). Independent of Phase 1, with a bounded interim
  exposure — after Phase 1 and before Phase 2, gc still *classifies*
  by pipe, but the orphan sweep already keys on state (Phase 1):
  - *Live Worker, held slot* (the case the hold exists for): safe.
    The non-`TERMINATED` state file protects the entry from the
    orphan sweep regardless of pipe presence.
  - *Verifiably dead Worker, non-`TERMINATED` state* (a crash no
    running `watch.sh` observes): gc reaps the stale pipe but the
    sweep spares the state file, so the slot stays held — the
    conservative direction (over-hold, never over-spawn) — until
    `orchctl recover` writes the exit record, or Phase 2's reap
    change lets gc write it (`crashed:detected-by-gc`) itself.
  Must precede Phase 3 (after which no pipes exist to iterate).
- **Phase 3** = `notify-complete.sh` and `spawn.sh` drop FIFO
  creation/write. Requires Phase 1 (once `mkfifo` is gone, a
  pipe-counting guard reads zero and over-spawns without bound) and
  Phase 2 (pipe-iterating tooling would see no Workers). Safe while
  the read path still exists: `watch.sh` already degrades to state
  polling when the pipe is absent (fact 1's `FIFO_MISSING` fallback).
- **Phase 4** = `watch.sh` drops the FIFO read path, by now dead code.

**The write side retires before the read side — never the reverse.**
If the read path went first, `spawn.sh` would still create pipes that
no reader ever opens, and every Worker's `notify-complete.sh` would
block forever on write-open — promoting fact 4's hazard from
"Orchestrator killed" to every normal completion. Phases 3 and 4 may
land as one PR; they must not land in the reverse order.

**Explicitly deferred: hook-based push.** A Worker `SessionEnd`/`Stop`
hook writing the terminal state would restore event-driven semantics (the
`SIGCHLD` analog; hooks verified to fire under `-p` and real installs,
#604). It is not part of this decision: a 5s poll meets the need, and
adding mechanism ahead of a measured latency problem violates parsimony.
Revisit if review-loop throughput ever makes 5s material.

### UNIX Philosophy Alignment

> Rule of Parsimony: "Write a big program only when it is clear by
> demonstration that nothing else will do."

Three detection sources where two suffice is mechanism beyond
demonstrated need. The FIFO's unique contributions — push latency and
slot tokening — are respectively negligible (fact 5) and misplaced
(fact 2). This is also the standing **platform-absorption** discipline:
what the platform's kernel now provides, cekernel stops hand-building.

> Rule of Repair: "When you must fail, fail noisily and as soon as
> possible."

The writer-hang hazard (fact 4) is the opposite: a silent, indefinite
stall at the Worker's final step, triggered precisely when things have
already gone wrong (Orchestrator killed). Retirement removes the hazard
class rather than wrapping it in timeouts.

> Rule of Representation: "Fold knowledge into data so program logic can
> be stupid and robust."

The completion payload moves fully into the state record (fact 3's gap
closes). One durable, inspectable file replaces an ephemeral in-flight
message; `watch.sh`'s logic gets dumber — read a file, compare a field.

> Rule of Least Surprise: "In interface design, always do the least
> surprising thing."

To a UNIX-literate reader, completion-via-pipe *looks* idiomatic but is
not — parents reap children through kernel accounting (`wait()`), and
nothing in an OS limits process count by counting pipes. The two-source
model matches the reader's OS intuition: process table + exit status.

### Platform Constraints

- `claude agents --json` remains behind the ADR-0018 contract
  (`claude-bg.sh` is the sole owner); this decision adds no new platform
  surface and changes no verdict semantics. The `watch.sh` degradation
  policy for `query-failed`/`unknown-value` is untouched.
- **Staleness (Evolving)**: if the platform ships native completion
  events for background sessions (plausible; cf. agent-teams research
  #200), the polling half of this design is the next absorption
  candidate. That is expected, not a defect — record and revisit.

## Alternatives Considered

### Alternative: Keep the triple-path as is

Status quo. Rejected: it retains a verified hazard (fact 4), a
misdocumented hidden coupling (fact 2 — the "notification channel" is
actually the concurrency token), and duplicated payload with a lossy
fallback (fact 3). The operational evidence is that the fallback path
works; the FIFO adds risk, not capability.

### Alternative: Keep the FIFO as an optional fast path

Make it configuration. Rejected on Rule of Simplicity: two permanent code
paths for one event, doubled test surface, and the optionality already
exists implicitly — which is how the hidden coupling went unnoticed.
Optional mechanisms rot.

### Alternative: Replace the FIFO with hook push now

Skip polling; have Worker lifecycle hooks push terminal state. Rejected
for this cycle on Rule of Optimization ("prototype before polishing"):
it adds a mechanism before a measured need, and couples completion
detection to hook delivery — a surface whose non-interactive behavior we
have only just finished characterizing (#604). Deferred, not refused.

## Consequences

### Positive

- One mechanism deleted end-to-end: `mkfifo`, the blocking-read loop, the
  FIFO write, and the writer-hang hazard class.
- Slot accounting becomes explicit and inspectable (state files) instead
  of incidental (pipe existence), and every slot release leaves a durable
  record — a state-file exit record, or the lifecycle log on the reap
  path (retained by cleanup, collected only by an explicit `orchctl gc`)
  — so `orchctl list` and the records tell the same story.
- Process tooling (`orchctl`, `process-status.sh`) enumerates one
  durable artifact instead of a pipe that doubles as a roster key.
- The fallback path stops being second-class: payload parity closes the
  detail gap; there is only one path to test.
- `watch.sh` loses its most intricate branch (fd 3 lifecycle,
  `exec 3<>`/`3>&-` bookkeeping).

### Negative

- Completion detection latency: sub-second → ≤5s (accepted: <1% of
  Worker lifecycle).
- Migration risk in slot accounting — the guard is load-bearing for
  scheduler correctness; Phase 1 must land with behavior tests
  (ADR-0017: assert effects, never text).
- Unverified exits (timeout, query-escalated) now **hold** their slot
  until `orchctl recover`/`kill` writes the exit record or the timeout
  protocol reaps via `cleanup-worktree.sh --force`, where the FIFO
  model freed it mechanically. Chosen deliberately (fail-safe against
  over-spawn), but a stalled Orchestrator that never resolves doubt now
  costs a slot instead of silently over-committing — surface it, don't
  hide it (Rule of Repair).
- Loses the event-driven wakeup pattern; if a future consumer needs
  sub-second reaction, it must build on hooks (deferred option), not
  pipes.
- Between a `blocked` exit record and the cleanup that stops the
  session, the state file (`TERMINATED`) and the process table
  (alive) intentionally disagree. Tooling that cross-checks the two
  must treat the exit record as authoritative for scheduling and the
  process table as authoritative for cleanup.

### Trade-offs

Push vs. poll: `select()`-style blocking is elegant, but elegance in a
mechanism whose latency budget is 1000× the poll interval is ornament.
The OS analogy is preserved at the level that matters — kernel accounting
for liveness, exit records for semantics — and consciously re-drawn where
it was cosmetic (the pipe). The analogy serves the design; the design
does not serve the analogy.
