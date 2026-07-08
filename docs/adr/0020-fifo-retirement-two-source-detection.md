# ADR-0020: Retire the Completion FIFO — Two-Source Detection

## Status

Proposed

## Context

Worker completion is detected through three sources:

| Source | Role | Latency |
|---|---|---|
| FIFO (`worker-<issue>`) | push notification **+ concurrency-slot token + roster key** | sub-second |
| state file (`worker-<issue>.state`) | semantic record — *what happened* | poll |
| `claude agents --json` | liveness verdict (ADR-0018) — *is it still running* | poll |

The FIFO predates the v2 platform. Under v1's `-p` fork model there was no
supervisor, so parent–child completion signaling was hand-built. ADR-0016 gave
cekernel a kernel-grade process roster; ADR-0012 Amendment 2 already moved the
Reviewer off the FIFO. Five facts establish that the FIFO now costs more than it
carries:

1. **It is already optional.** `notify-complete.sh` writes the state file *first*
   and exits 0 when the FIFO is absent; `watch.sh` falls back to state polling.
   The FIFO is de facto optional today — but the exit-0 path is lossy: it returns
   before the terminal issue-lock release, so a pipe-less completion leaks the
   issue lock (and loses the lifecycle-log append).
2. **Its load-bearing role is not notification.** `spawn.sh`'s concurrency guard
   counts pipes (`active_worker_count`), and `watch.sh`'s `rm -f "$fifo"` frees
   the slot — the FIFO *is* the concurrency-slot token (ADR-0012).
3. **The fallback loses payload.** The state file carries the result (`ci-passed`)
   but not the notify detail (PR number); fallback results substitute
   `detected-via-state-fallback`.
4. **It has a verified writer-hang hazard.** A write to a reader-less pipe blocks
   forever. If the Orchestrator is SIGKILLed leaving the pipe, the Worker's
   `notify-complete.sh` hangs at the write — the state write has landed, but the
   lifecycle-log append and issue-lock release never run, so the hang also holds
   the issue lock and blocks re-spawn.
5. **Push latency is not load-bearing.** FIFO push is sub-second; state polling
   detects within seconds. Worker lifecycles are minutes to hours — polling
   latency is <1%.

In OS terms: v1 had no kernel, so a hand-rolled pipe was honest IPC; v2 has a
kernel, and a real parent learns of a child's exit from `wait()`/`SIGCHLD` —
kernel accounting — not a pipe the child writes to before dying (a crashed child
writes nothing, which is why the liveness source exists). Counting pipes to cap
concurrency has no OS analog at all. The analogy argues *for* retirement.
cekernel is a transitional artifact by design: what the platform's kernel now
provides, it stops hand-building.

Four further couplings constrain *how* the FIFO is removed (implementation
detail, not motivation):

| # | Coupling | Consequence for migration |
|---|---|---|
| 6 | **Roster + name-resolution key.** `orchctl ls`/`gc`, `process-status.sh`, `health-check.sh` discover Workers by iterating pipes; `resolve_target` resolves *every* targeted command by pipe existence. | A pipe-less Worker is unlisted *and* unaddressable. `health-check.sh` couples deepest — its zombie *definition* is "FIFO exists but process dead." |
| 7 | **Reaper is a slot-release site.** `cleanup-worktree.sh` removes the pipe ("so slots do not leak") and is the terminus of the timeout protocol. | Any slot-accounting migration must give the reaper explicit semantics. |
| 8 | **Reap erases the lifecycle log.** `cleanup-worktree.sh` deletes `logs/worker-<issue>.log`; `gc` sweeps logs for pipe-less issues. | A record-beats-erasure claim on the reap path must change log retention explicitly. |
| 9 | **gc reaps by pipe absence.** `gc` classifies pipes by liveness (ADR-0018 refuse-on-doubt), removes stale ones, then deletes every `worker-*.*` companion — the state file included — for any pipe-less issue. | Under state-based accounting, deleting a non-`TERMINATED` state file *frees the slot* — an over-spawn side door. |

## Decision

Retire the FIFO in 2.1. Completion becomes **two sources on distinct axes**: the
state file is the semantic record; `claude agents --json` is liveness.

**1. State carries the full payload.** `notify-complete.sh` writes
`TERMINATED:<ts>:<result>:<detail>`; `watch.sh`'s `build_result_from_state`
splits result and detail, closing the fallback gap (fact 3).

**2. Slot accounting moves to state files.** `active_worker_count()` counts
`worker-*.state` files whose state is not `TERMINATED`. On the normal path a slot
frees the instant `notify-complete.sh` writes `TERMINATED` — the same moment the
FIFO removal frees it today, preserving ADR-0012 semantics (slot free during
review, worktree retained). `watch.sh` writes the exit record where the verdict
is verified, per exit class:

| `watch.sh` exit | Verdict | State write | Slot |
|---|---|---|---|
| completion (state read) | verified | already `TERMINATED` | frees |
| crashed (`done`/`stopped`/`not-listed`/`missing`) | verified | `TERMINATED:<ts>:crashed:<detail>` | frees |
| blocked | verified | `TERMINATED:<ts>:blocked:<detail>` | frees |
| timeout | **unverified** | none | held |
| query-escalated | **unverified** | none | held |

Holding the slot on unverified exits is a deliberate change from the FIFO model
(which freed it even when "worker may still be running"): on doubt, refuse to
free — over-holding degrades throughput, over-freeing over-spawns past
`MAX_ORCH_CHILDREN`. Same posture as `orchctl gc` (ADR-0018).

**Invariant — terminal records are write-once.** *No write ever replaces an
existing `TERMINATED` record.* Three writers obey it:

- **`watch.sh`** re-reads the state file before writing a `crashed`/`blocked`
  record; if it is already `TERMINATED`, it consumes that as the completion
  result. A dead verdict *plus* a `TERMINATED` record is normal completion — the
  two-source semantics resolve the race that a table-literal write would lose.
- **`orchctl gc`**'s reap write (`crashed:detected-by-gc`) is scoped to
  non-`TERMINATED` entries — its stale classes include "`TERMINATED` with no live
  handle," which an unscoped write would clobber while reaping.
- **`orchctl kill`**'s `TERMINATED:killed` write is scoped to non-`TERMINATED`
  entries — an operator killing an already-completed Worker (`TERMINATED:ci-passed`,
  review pending) must not relabel the completion, which would strand the issue
  non-resumable (`resume` addresses only `TERMINATED:crashed`) and erase the PR
  detail. The session stop kill performs stays unconditional (a no-op on a
  finished session; also the stop a `TERMINATED:blocked` record needs).

**Held slots survive gc without retaining the pipe.** Retaining the pipe on
unverified exits would reintroduce fact 4's hazard (a reader-less pipe a later
completion blocks on). Instead the **protection key changes**: a non-`TERMINATED`
state file marks the issue active regardless of pipe presence, and
`resolve_target` resolves by state-file existence — so the doubt resolvers can
address pipe-less held slots. The state key is a superset of the pipe key (a
state file is written unconditionally at spawn, and no path removes one while its
pipe exists), so nothing addressable today becomes unaddressable. Doubt is
resolved by the operator paths that already write the exit record: `orchctl
recover`, `orchctl kill`, and `orchctl gc` (whose reap write replaces the pipe
removal).

**The reaper reaps.** `cleanup-worktree.sh` is the reap step — deleting the state
file retires the roster entry and frees the slot, as `wait()` consumes a zombie.
Reaping a `TERMINATED` entry needs no record; reaping a non-`TERMINATED` entry
appends the exit event to the lifecycle log before deletion. The condition is the
**state, not `--force`**: the timeout protocol's Worker-dead branch is unspecified
and reaches cleanup unflagged. Two changes follow — cleanup must **retain** the
log (today it deletes it, fact 8) so the record survives to gc's orphan sweep,
and orchestrator.md must wire the unspecified branch (Worker dead after TERM →
plain `cleanup-worktree.sh`).

**One row is asymmetric by design.** `blocked` records a still-*alive* session
(stalled on a permission dialog) as `TERMINATED` — terminal **by policy** (nobody
approves a dialog headless). The exit record leads the process table until
cleanup stops the session, so the pairing is normative: a `blocked` record is
always followed by session stop in the same handling step. orchestrator.md routes
only timeout/CI/Reviewer failure today, so this handler is added alongside the
timeout branch.

**3. Polling splits by cost.** `watch.sh` polls the state file every
`CEKERNEL_STATE_POLL_INTERVAL` (5s, local fs) and queries the backend every
`CEKERNEL_POLL_INTERVAL` (30s, unchanged — `agents --json` spawns a process).
Completion latency: sub-second → ≤5s.

**4. Roster enumeration moves to state files.** The pipe-iteration consumers
(fact 6) — `orchctl ls`/`gc`, `process-status.sh`, `health-check.sh` — enumerate
`worker-*.state` via one shared helper in `worker-state.sh`, filtering to
non-`TERMINATED` (reproducing "a pipe exists only while a Worker is active").
`orchctl ps` already enumerates handle files and does not migrate.
`health-check.sh` is a redesign, not a key swap: its zombie predicate becomes
**non-`TERMINATED` state + dead backend verdict** — exactly Decision 2's held
slot, so a zombie flag now points at the doubt `orchctl recover` resolves.

**5. Deletions.** `mkfifo` (`spawn.sh`), the FIFO branch (`watch.sh`), the FIFO
write (`notify-complete.sh`), pipe iteration (`orchctl`, `process-status.sh`,
`health-check.sh`), pipe removal (`cleanup-worktree.sh`), and the writer-hang
hazard all go. Prose and comments describing the FIFO update in the same sweep:
`README.md`'s OS-concept table (completion = process table + exit record;
semaphore = non-`TERMINATED` count; the "IPC pipe" row removed),
`docs/internals.md`'s `## IPC: Named Pipe` section and concurrency-limit wording,
`agents/orchestrator.md`, `skills/references/postmortem-patterns.md`'s FIFO
detection patterns, `docs/claude-code-constraints.md`, `CLAUDE.md`, and the FIFO
comments in `worker-state.sh` / `worker-priority.sh` / `spawn-orchestrator.sh` /
`agents/reviewer.md`. The FIFO-coupled test surface — every `mkfifo`-fixtured
suite, the `assert_fifo_exists` helper, and `test-watch-state-fallback.sh` (which
fixtures the FIFO's *absence*) — migrates with the phase that retires the
behavior it fixtures (ADR-0017: tests assert the behavior each phase ships).

### Phasing

Order is load-bearing: **the write side retires before the read side, never the
reverse.** A read-first order would leave `spawn.sh` creating pipes no reader
opens, promoting fact 4's hazard to every normal completion.

| Phase | Contents | Depends on |
|---|---|---|
| **1** | state detail (1) + `watch.sh` terminal writes + slot migration (2); orphan-sweep protection key + `resolve_target` key (facts 6, 9); reaper log-retain + log-before-delete (facts 7, 8); wire orchestrator.md timeout-dead branch + `blocked` handler; `kill` write-once guard; env catalog for `CEKERNEL_STATE_POLL_INTERVAL` / `CEKERNEL_POLL_INTERVAL` | — |
| **2** | roster enumeration (4) + `gc` reap change (pipe removal → `TERMINATED` write, non-`TERMINATED` only) | must precede 3 |
| **3** | drop FIFO create/write (`spawn.sh`, `notify-complete.sh`); delete the FIFO-missing early return so lock release + log append run unconditionally (closes fact 1) | 1, 2 |
| **4** | drop FIFO read path (`watch.sh`), now dead code | 3 |

Phase 1's terminal-state writes are the slot-release mechanism, not an
optimization: once counting is state-based, a crashed Worker whose exit record
nobody writes leaks its slot. Phases 3–4 may land as one PR. Between Phase 1 and
2, gc still classifies by pipe but the orphan sweep already keys on state — a
verifiably-dead Worker with a non-`TERMINATED` state holds its slot (over-hold,
never over-spawn) until `recover` or Phase 2's gc writes the exit record.

**Deferred: hook-based push.** A Worker `SessionEnd`/`Stop` hook writing terminal
state would restore event-driven semantics (the `SIGCHLD` analog; hooks fire
under `-p`, #604). Not part of this decision: a 5s poll meets the need, and
adding mechanism ahead of a measured latency problem violates parsimony. Revisit
if review-loop throughput makes 5s material.

## UNIX Philosophy Alignment

- **Parsimony** — three sources where two suffice. The FIFO's unique
  contributions are negligible (fact 5) and misplaced (fact 2).
- **Repair** — the writer-hang (fact 4) is a silent, indefinite stall holding the
  issue lock, triggered exactly when things have already gone wrong. Retirement
  removes the hazard class rather than wrapping it in timeouts.
- **Representation** — the payload moves into the durable state record;
  `watch.sh`'s logic gets dumber: read a file, compare a field.
- **Least Surprise** — completion-via-pipe *looks* idiomatic but isn't. Parents
  reap through kernel accounting, and nothing in an OS limits process count by
  counting pipes. Two-source = process table + exit status.

## Platform Constraints

- `claude agents --json` stays behind the ADR-0018 contract (`claude-bg.sh` sole
  owner); this adds no platform surface and changes no verdict semantics.
- **Staleness (Evolving)**: if the platform ships native completion events for
  background sessions (cf. #200), the polling half is the next absorption
  candidate. Expected, not a defect.

## Alternatives Considered

- **Keep the triple-path.** Rejected: retains a verified hazard (fact 4), a
  misdocumented hidden coupling (fact 2), and a lossy fallback (fact 3). The FIFO
  adds risk, not capability.
- **Keep the FIFO as an optional fast path.** Rejected on Simplicity: two
  permanent code paths for one event, doubled test surface — and the optionality
  already exists implicitly, which is how the coupling went unnoticed. Optional
  mechanisms rot.
- **Replace with hook push now.** Rejected for this cycle on Optimization
  ("prototype before polishing"): adds mechanism before a measured need and
  couples completion to hook delivery, a surface only just characterized (#604).
  Deferred, not refused.

## Consequences

**Positive**

- One mechanism deleted end-to-end, including the writer-hang hazard class.
- Slot accounting becomes explicit and inspectable; every slot release leaves a
  durable record (a state exit record, or the retained lifecycle log on the reap
  path).
- Tooling enumerates one durable artifact instead of a pipe doubling as a roster
  key.
- The fallback stops being second-class: payload parity, one path to test.
- `watch.sh` loses its most intricate branch (fd 3 lifecycle).

**Negative**

- Latency sub-second → ≤5s (<1% of lifecycle).
- Slot accounting is load-bearing for scheduler correctness; Phase 1 must land
  with behavior tests (ADR-0017: assert effects, never text), including the
  write-once race.
- Unverified exits now hold their slot until a resolver writes the exit record,
  where the FIFO model freed it mechanically — fail-safe against over-spawn, but
  a stalled Orchestrator now costs a slot instead of silently over-committing.
- Loses the event-driven wakeup; a future sub-second consumer must build on hooks,
  not pipes.
- Between a `blocked` record and cleanup, the state file (`TERMINATED`) and
  process table (alive) intentionally disagree — treat the exit record as
  authoritative for scheduling, the process table for cleanup.

**Trade-offs**

Push vs. poll: `select()`-style blocking is elegant, but elegance in a mechanism
whose latency budget is 1000× the poll interval is ornament. The OS analogy is
kept where it matters (kernel accounting for liveness, exit records for
semantics) and consciously re-drawn where it was cosmetic (the pipe). The analogy
serves the design, not the reverse.
