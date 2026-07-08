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
FIFO (subagent return value). The FIFO's remaining user is the Worker
completion path.

Investigation (#586, 2026-07-08) established five facts:

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
   counts `worker-*.state` files whose state is not `TERMINATED`. A slot
   frees the moment `notify-complete.sh` writes `TERMINATED` — the same
   instant the FIFO removal frees it today, preserving ADR-0012's slot
   semantics (slot free during review, worktree retained). Stale
   non-terminal state from crashed Workers is handled by the existing
   `orchctl recover` path, unchanged.
3. **Polling splits by cost.** `watch.sh` polls the state file every
   `CEKERNEL_STATE_POLL_INTERVAL` (default 5s, local fs, negligible) and
   queries the backend verdict every `CEKERNEL_POLL_INTERVAL` (default
   30s, unchanged — `agents --json` spawns a process). Completion
   latency: sub-second → ≤5s.
4. **Deletions.** `mkfifo` leaves `spawn.sh`; the FIFO branch leaves
   `watch.sh`; the FIFO write leaves `notify-complete.sh`; the writer-hang
   hazard ceases to exist. `README.md`'s OS-concept table re-maps IPC:
   completion = process table + exit record (`agents --json` + state
   file), not pipes.

Phasing (each independently mergeable and revertable): Phase 1 = state
detail + slot migration (FIFO still present, now redundant); Phase 2 =
`watch.sh` drops the FIFO path; Phase 3 = `notify-complete.sh` and
`spawn.sh` drop FIFO creation/write.

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
  of incidental (pipe existence).
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
- Loses the event-driven wakeup pattern; if a future consumer needs
  sub-second reaction, it must build on hooks (deferred option), not
  pipes.

### Trade-offs

Push vs. poll: `select()`-style blocking is elegant, but elegance in a
mechanism whose latency budget is 1000× the poll interval is ornament.
The OS analogy is preserved at the level that matters — kernel accounting
for liveness, exit records for semantics — and consciously re-drawn where
it was cosmetic (the pipe). The analogy serves the design; the design
does not serve the analogy.
