# ADR-0017: Test Suite Overhaul for v2

## Status

Proposed

## Context

The v2 re-architecture (ADR-0015, ADR-0016, ADR-0012 Amendment 2) invalidates
a significant share of the existing test suite, which makes this the right
moment to fix structural debt rather than patch around it.

### Current state (inventoried 2026-07-06)

- **76 test files, 9,781 LOC** against **47 scripts, 5,650 LOC** (1.73:1).
- Custom harness: `run-tests.sh` (sequential, file-granular pass/fail) +
  `helpers.sh` (7 assert functions, 94 LOC). No per-test isolation, no
  filtering, no setup/teardown contract, no TAP output.
- **Duplication clusters**: 12 files target `spawn.sh`, 6 target `watch.sh`,
  5 near-identical zsh-compat clones (~367 LOC), 4 target `orchctl.sh`
  (1,117 LOC), 9 form a scheduler backend matrix, 3–4 files each for
  `process-status.sh`, `notify-complete.sh`, `load-env.sh`, `issue-lock.sh`.
- **v2 casualties**: ~15 files hard-code `claude -p --agent` argv or grep
  generated runner text (`assert_match "exec claude -p --agent" ...`).
  These assert on **emitted shell text rather than behavior** — they break
  on any spawn-mechanism change even when behavior is preserved. ADR-0016
  changes exactly that mechanism.
- **Mocking is ad hoc**: four coexisting patterns (PATH shim, shell function
  override, fixture files/env vars, real `git worktree`), four different
  variable names for the same shim dir, and the PATH-shim vs function split
  is arbitrary even though the two are not interchangeable (function
  overrides don't survive `exec`/subshell spawn paths).
- One pure `.md`-grep test (`ctl/test-max-orchestrators-env.sh`) survives
  under the CLAUDE.md regression-guard exception.

## Decision

Four decisions, in dependency order.

### 1. Adopt bats-core as the test framework

bats-core is TAP-compliant, requires only **bash 3.2+** (macOS default
works), installs via brew locally and a pinned git checkout or setup action
in CI, and provides what the custom harness lacks: per-`@test` isolation,
`setup()`/`teardown()`, `--filter`, parallel execution, and standard output
formats.

- Assertions use bats-core's `run` + plain bash conditionals; existing
  `assert_*` helpers are ported to a small `tests/helpers/assertions.bash`
  so migration is mostly mechanical (`bats-assert` is NOT vendored —
  two fewer submodules; revisit if assertion needs grow).
- CI pins the bats-core version; local dev documents `brew install
  bats-core`.
- The custom `run-tests.sh` remains during migration and runs both suites
  (legacy `test-*.sh` + new `*.bats`); it is deleted when the last legacy
  file is gone.

**Why not keep the custom harness** (95 LOC, zero deps): it optimizes the
wrong constant. The cost of the suite is its 9,781 LOC of duplicated setup
and ad-hoc mocks, not the harness. bats' per-test isolation and fixtures
directly attack that duplication; a home-grown equivalent would grow into a
worse bats (Rule of Least Surprise: contributors already know bats).

### 2. One canonical mock layer

- `tests/helpers/mock-bin.bash`: a single `mock_bin <cmd> <script-body>`
  helper (PATH-shim pattern, one variable name, auto-cleanup in
  `teardown`). **PATH shims are the only sanctioned mock style** — function
  overrides are banned because they silently fail across `exec` boundaries.
- `tests/helpers/mock-claude.bash`: the canonical `claude` shim for v2. It
  emulates the delegated-spawn contract observed on v2.1.201 (ADR-0016):
  `--bg` prints `backgrounded · <short-id>` and records argv; `agents
  --json` replays a scriptable state sequence (`busy` → `done` /
  `blocked`); `stop <id>` records the call. Tests assert on recorded argv
  and state-machine effects, never on generated script text.
- `git` and `git worktree` stay **real** against temp repos: they are fast,
  hermetic, and mocking them would fake the exact behavior worktree tests
  exist to verify. This is now policy, not accident.

### 3. Re-target spawn-path tests to the v2 contract

- The ~15 `claude -p` argv/text-grep files are **not migrated**. Their
  subjects are rewritten under ADR-0016; their replacements test the new
  observable contract: session-ID capture from `agents --json`, `blocked`
  state surfacing, `claude stop` on cleanup, `CEKERNEL_SPAWN_MODE`
  switching, and FIFO/state/lock behavior (which is spawn-agnostic and
  carries over).
- Reviewer spawn tests (`test-spawn-reviewer.sh`) retire together with
  `spawn-reviewer.sh` (ADR-0012 Amendment 2); while legacy mode exists they
  keep running in the legacy lane.
- Rule going forward: **assert behavior (executed effects, recorded argv),
  never emitted script text.** Text-grep of generated runners is the same
  anti-pattern as `.md`-grep, one layer down.

### 4. Consolidate by subject

Target shape: **one `.bats` file per script under test**, variants become
`@test` cases within it. Concretely:

| Cluster | Now | Target |
|---------|-----|--------|
| `spawn.sh` family | 12 files | 3 (core contract / guards+locks / rollback) |
| `watch.sh` | 6 files | 2 (loop+detection / logging) |
| zsh-compat clones | 5 files (~367 LOC) | 1 parametrized file (loop over sourced helpers under zsh) |
| `orchctl.sh` | 4 files | 2 (read subcommands / mutating subcommands) |
| scheduler matrix | 9 files | 5 (CLI×2, backend×2 parametrized, wrapper+preflight+registry merged sensibly) |
| `process-status.sh`, `notify-complete.sh`, `load-env.sh`, `issue-lock.sh` | 3–4 each | 1 each |

- `ctl/test-max-orchestrators-env.sh` (pure `.md` grep) is **deleted**; the
  regression it guards is covered by behavior tests of `orchctl count`
  enforcement. The CLAUDE.md exception stays available for env-profile
  changes but this file no longer qualifies.
- Expected end state: **~35–40 bats files**, roughly halving test LOC while
  increasing per-test isolation. Coverage policy is unchanged: behavior of
  executable scripts only (CLAUDE.md Testing section remains authoritative).

### Migration order

1. Bootstrap: bats harness + `mock-bin`/`mock-claude` helpers + CI dual-run
   (one PR, no test semantics change).
2. Consolidation of **v2-stable** subjects (zsh-compat, load-env,
   issue-lock, notify-complete, process-status, orchctl, scheduler) —
   mechanical batches, each PR deletes what it replaces.
3. v2 contract tests land **with** each ADR-0016 phase (spawn/watch/backends
   rewrite in the same PR as the script change, TDD where applicable).
4. Delete `run-tests.sh` legacy lane + remaining `-p` era tests when
   `CEKERNEL_SPAWN_MODE=legacy` is removed.

## Alternatives Considered

### Keep the custom harness, consolidate only

- **Pro**: zero new dependencies.
- **Con**: leaves no per-test isolation and no filtering; consolidated
  files get *longer* and harder to debug without them; every future
  contributor re-learns a bespoke harness.
- **Rejected**: the harness is the enabler for the consolidation, not an
  independent axis.

### shunit2 instead of bats-core

- **Pro**: single-file, no submodule.
- **Con**: less active, no TAP by default, weaker isolation model, smaller
  contributor familiarity.
- **Rejected**: bats-core is the de-facto standard (Rule of Least Surprise).

### Big-bang rewrite of all 76 files

- **Pro**: one consistent suite immediately.
- **Con**: a giant untestable PR; v2 spawn contract isn't implemented yet,
  so spawn tests would be rewritten twice.
- **Rejected**: migration phases align with ADR-0016 phases instead.

## Consequences

### Positive

- Spawn-mechanism changes (ADR-0016 phases) stop breaking text-grep tests;
  the mock-claude contract is the single point of update.
- ~50% test LOC reduction with better isolation and single-test filtering.
- One documented mock pattern ends the PATH-shim/function-override drift.

### Negative

- New dev dependency (bats-core) — pinned and brew-installable, but no
  longer "clone and run".
- Dual-lane CI during migration adds runner complexity temporarily.
- Contributors must learn the "behavior, not emitted text" rule; enforced
  in review via CLAUDE.md update (follow-up).

## Follow-ups

- Implementation issues: (1) harness bootstrap + CI, (2) mock helpers,
  (3) consolidation batches per cluster, (4) v2 contract tests per
  ADR-0016 phase.
- CLAUDE.md: add "assert behavior, never emitted script text" to the
  Testing section; update test-file naming for `.bats`.
