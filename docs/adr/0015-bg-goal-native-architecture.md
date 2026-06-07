# ADR-0015: cekernel v2 — bg-goal Native Architecture

## Status

Proposed

## Context

cekernel's current architecture (v1) spawns Workers and Reviewers via `claude -p`
in independent OS processes, coordinates them through file-based IPC (FIFO
notifications, state files, checkpoint files), and tracks lifecycle via a hand-built
state machine (`phase-transition.sh`, `worker-state.sh`, `notify-complete.sh`,
`watch.sh`, `health-check.sh`). The Orchestrator agent runs in the main worktree
and orchestrates this pipeline.

Three Claude Code primitives now exist that overlap substantially with what
cekernel built:

1. **`claude --bg`** (v2.1.154, shipped in v2.1.153 as a hidden flag) — spawns a
   background session that runs to completion under daemon supervision. Returns a
   session ID. Combined with `--permission-mode auto` and a slash command like
   `/goal <condition>`, it becomes a self-driving autonomous agent that runs until
   the goal evaluator confirms completion.

2. **`claude agents --json`** (v2.1.139 / `--json` since v2.1.145) — lists running
   background sessions with `sessionId`, `pid`, `cwd`, `kind`, `status`, `name`.
   Effectively the dashboard equivalent of cekernel's `process-status.sh` and
   `orchctl ps`.

3. **`claude attach <id>`, `claude logs <id>`, `claude stop <id>`,
   `claude daemon (status|stop|...)`** — supervisor and session control primitives,
   roughly equivalent to cekernel's `send-signal.sh`, `watch-logs.sh`,
   `cleanup-worktree.sh --force`, and `orchctl gc`.

We empirically verified through two PoCs (issues #536 → PR #537 via default Claude,
and issue #538 → PR #539 via `--agent cekernel:worker`) that:

- A `claude --bg --permission-mode auto --plugin-dir <root> --add-dir <worktree>
  --agent <name> "/goal <observable condition>"` invocation autonomously implements
  an issue from a fresh worktree to a CI-green PR in ~3–4 minutes
- The agent honors target-repo CLAUDE.md conventions (conventional commits, PR
  templates, `closes #N`, `Co-Authored-By` trailers, language conventions)
- The `cekernel:worker` agent definition works as-is in this context. When it
  cannot find `phase-transition.sh` or `.cekernel-env`, it probes once, then
  proceeds with a "simplified Worker lifecycle"; the prompt's policy layer
  (`gh issue comment`-based plan/result, TDD rules, self-merge restraint) is
  preserved while the orchestration-protocol layer is silently skipped
- OAuth via macOS keychain works for bg sessions, but the daemon must inherit
  enough environment to talk to Security framework. `env -i` strips required
  variables and the new daemon will report `auth: no token found` indefinitely.
  Replacing `env -i` with selective `unset` of nested-session markers
  (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ACCESS_TOKEN`)
  preserves keychain access
- The `/postmortem` skill works on bg session transcripts unchanged; the
  transcript-locator path heuristic resolves the right file via the worktree
  naming convention

The pressure to change is also external: official docs state that `--bare` will
become the default for `-p` in a future release. v1's `wrapper.sh`,
`spawn-orchestrator.sh`, `headless.sh`, and `runner.sh` all rely on `-p` and will
need explicit context injection regardless. The `--bare` migration (#532, PR #535)
is the minimal future-proofing; v2 is the architecturally clean response.

## Decision

Migrate cekernel toward a **bg-goal native architecture** in which:

1. **Worker and Reviewer are spawned as `claude --bg` sessions** with
   `--permission-mode auto`, `--plugin-dir <cekernel-root>`,
   `--add-dir <worktree>`, `--agent <name>`, and a positional `/goal <condition>`
   prompt whose completion criterion is externally observable (PR exists with
   CI green; review record posted on PR). The spawn command returns a session
   UUID which cekernel persists as the canonical handle.

2. **Lifecycle observation is delegated to `claude agents --json`** plus polling
   of the externally observable signals (gh PR state, CI state, review records).
   FIFO IPC, `notify-complete.sh`, phase state files, `watch.sh`, and
   `health-check.sh` are retired from this code path.

3. **The Orchestrator becomes a thin coordinator** that handles:
   - issue triage and worktree creation (preserved from v1)
   - issue lock acquisition (preserved)
   - Worker spawn → wait for completion → check PR/CI state → Reviewer spawn
     → wait → decide merge/re-spawn/escalate → worktree cleanup
   - concurrency limit (`CEKERNEL_MAX_ORCH_CHILDREN`) and priority scheduling
     (preserved — these are cekernel's value-add, not in Claude Code primitives)
   - OS scheduler (`/cron`, `/at`) integration (preserved)
   The Orchestrator no longer manages a process tree, FIFO directory, or
   custom state machine — it observes Claude Code's daemon-tracked sessions and
   GitHub state.

4. **A thin `agents/worker-policy.md` (agent name `worker-policy`) is
   introduced alongside the existing `agents/worker.md`**, carrying the
   policy layer: plan comment shape, result comment shape, TDD rules,
   self-merge restraint, target-repo authority. v2 sessions are spawned
   with `--agent <plugin>:worker-policy`; v1 sessions continue to use
   `--agent <plugin>:worker` (and thus continue to load the full `worker.md`
   superset). The original `worker.md` is **not** renamed — the agent name
   `worker` is referenced by spawn scripts and namespace-detection logic
   throughout the codebase, and renaming would ripple far beyond this ADR.
   The least-surprise hazard of "`worker.md` silently means the legacy
   contract" is addressed by a short header comment in `worker.md` pointing
   readers at `worker-policy.md`. `agents/reviewer.md` and
   `agents/reviewer-policy.md` follow the same pattern.

5. **Both spawn paths coexist during the migration**, gated by
   `CEKERNEL_SPAWN_MODE=legacy|bg-goal` (default `legacy` until v2 is hardened).
   `spawn-worker.sh` and `spawn-reviewer.sh` dispatch on this variable.

   **Backend × SPAWN_MODE matrix**: `bg-goal` is **headless-only**. When
   `CEKERNEL_BACKEND` is `wezterm` or `tmux` and `CEKERNEL_SPAWN_MODE=bg-goal`,
   `spawn.sh` silently downgrades to `legacy` for that spawn and emits a
   one-line stderr notice the first time it does so per session. Rationale:
   `claude --bg` detaches the process from any terminal, defeating the
   pane-as-progress-window UX that motivates the wezterm/tmux backends. An
   operator who wants `bg-goal` semantics on those backends must explicitly
   set `CEKERNEL_BACKEND=headless`. A future Phase X may introduce a
   `claude attach`-based re-attach pattern that restores the visualization
   layer; that is out of scope for this ADR.

   **Version floor**: v2 paths require `claude --version >= 2.1.154`
   (the version that documents `--bg` and `--bare` in `--help`).
   `spawn.sh` parses `claude --version` once at session start and falls
   back to `legacy` for any older installation, emitting a one-line stderr
   warning. The floor will be raised as `/goal`, `claude agents --json`,
   and `claude daemon` mature (track upstream changelog and bump as
   required behavior is added).

6. **`orchctl ps` becomes a thin formatter over `claude agents --json`**, with
   cekernel-specific columns (issue number, priority, lock state) joined from
   cekernel's own state. The shell layer that called `process-status.sh`,
   `health-check.sh`, and `send-signal.sh` is replaced by `claude agents`,
   `claude logs`, and `claude stop`.

7. **Spawn invocation avoids `env -i`** because it breaks new-daemon keychain
   auth on macOS. The canonical pattern is selective `unset` of nested-session
   markers, preserving everything else needed for Security framework access.
   `spawn.sh` MUST verify daemon auth state by reading `claude daemon status`
   when a spawn returns `authentication_failed` and emit a single-line stderr
   pointer naming the failing daemon and the recommended remediation (set
   `ANTHROPIC_API_KEY` or re-run interactively to refresh OAuth), so the
   operator does not debug "the Worker did nothing for 30 s" silently.

8. **`CEKERNEL_USE_BARE × CEKERNEL_SPAWN_MODE` matrix**: `bg-goal` mode
   inherently injects context explicitly via `--plugin-dir`, `--add-dir`,
   `--agent`, and the prompt, so `--bare` is **not** added on top of it.
   The matrix:

   | SPAWN_MODE | USE_BARE | Result |
   |---|---|---|
   | legacy | 0 | classical `claude -p --agent` (current behavior) |
   | legacy | 1 | `claude -p --bare --plugin-dir … --add-dir … --agent` (PR #535) |
   | bg-goal | 0 | `claude --bg --permission-mode auto --plugin-dir … --add-dir … --agent … "/goal …"` |
   | bg-goal | 1 | identical to `bg-goal,0` — `USE_BARE` is silently ignored with a one-line stderr notice |

### UNIX Philosophy Alignment

> Rule of Composition: "Design programs to be connected with other programs."

bg-goal explicitly composes with Claude Code's daemon, `claude agents`, `claude
attach`, and the `/goal` evaluator hook. v1 reimplemented an internal protocol
that those primitives now duplicate. v2 connects cekernel to Claude Code's
text-stream surfaces (JSON output of `claude agents`, `gh pr view --json`) rather
than to its own private FIFO format. Composition wins both at the implementation
level (fewer custom protocols) and at the operator level (`claude agents` works
without learning cekernel commands).

> Rule of Separation: "Separate policy from mechanism; separate interfaces from engines."

The current `worker.md` collapses policy ("post a plan comment, then a result
comment; follow target repo CLAUDE.md; don't self-merge") and mechanism
("`phase-transition.sh` at each boundary; write state file; notify via FIFO").
Splitting into `worker-policy.md` and `worker.md` (the v1 protocol layer)
cleanly separates the two. The policy layer is portable; the mechanism layer
becomes legacy-only.

> Rule of Simplicity: "Design for simplicity; add complexity only where you must."

v2 retires (at minimum): `notify-complete.sh`, `phase-transition.sh`,
`worker-state-write.sh`, `check-signal.sh`, `clear-resume-marker.sh`,
`create-checkpoint.sh`, `watch.sh`, `health-check.sh`, `send-signal.sh`,
`process-status.sh`, `worker-state.sh`, FIFO management, and the
state-machine documentation. That is roughly half of `scripts/process/` and
`scripts/orchestrator/`. The retired complexity moves to Claude Code's
daemon and the `/goal` evaluator, which are maintained upstream.

> Rule of Parsimony: "Write a big program only when it is clear by demonstration that nothing else will do."

The state machine, FIFO IPC, and watch.sh were the right call when they were
written — there was no Claude Code primitive that supplied them. With those
primitives now demonstrated to work (#536, #538), the parsimony argument
flips. Keeping the v1 protocol means writing and maintaining a "big program"
where a smaller one now suffices.

> Rule of Diversity: "Distrust all claims for 'one true way.'"

v2 does not deprecate v1. The two spawn paths coexist under
`CEKERNEL_SPAWN_MODE`. Users who need v1 semantics (cross-process FIFO,
SUSPEND/RESUME with `.cekernel-checkpoint.md`, OS-scheduler-triggered batches)
keep them. Users who want the v2 path opt in. Migration is gradient, not
binary.

> Rule of Repair: "When you must fail, fail noisily and as soon as possible."

The known `env -i` gotcha is a Rule-of-Repair concern: the daemon's failure
mode was "silently report 'no token found' every 30 s" while the spawned
session stub-returned `Not logged in · Please run /login`. The Decision
explicitly documents the spawn pattern that avoids this. `spawn.sh` in v2
must surface the daemon's auth state (e.g., parse `claude daemon status`
output) when a bg spawn returns auth_failed, so the operator sees the cause
immediately instead of debugging "the worker did nothing for 30 s."

### Platform Constraints

The following Claude Code constraints (per `docs/claude-code-constraints.md`)
materially shape this decision:

- **Background Tasks (Confidence: Evolving)** — bg sessions and their
  notifications are evolving primitives. v2 depends on `claude --bg`,
  `claude agents`, `claude attach`, `claude daemon`, and `/goal` (a slash
  command that is itself a session-scoped Stop hook wrapper). All four are
  in active development. The staleness risk is real and is explicitly
  accepted in the trade-offs below; the migration is gated to allow rollback.

- **No Shared State Between Sessions (Confidence: Stable)** — v2 still relies
  on file-based coordination for cekernel-owned concerns (issue lock,
  worktree, lifecycle log). The Claude Code daemon provides session-level
  shared state (the agent list) but not cekernel's domain state.

- **Worker Process Backend (Confidence: Stable)** — v2 reshapes the headless
  backend (`scripts/shared/backends/headless.sh`) to spawn via `claude --bg`
  instead of `claude -p`. The wezterm/tmux backends keep `claude -p` for their
  visualization purpose (a bg session detached from a pane defeats the
  pane-as-progress-window UX); they may opt into a `claude attach`-based
  re-attach pattern later.

- **Subagent Nesting Limitation (Confidence: Stable)** — v2 does not change
  the nesting story. Worker/Reviewer continue as independent OS-tracked
  processes (now daemon-tracked rather than process-group-tracked).
  Clarification: `claude --bg` invoked from inside an Orchestrator (itself
  a skill-spawned subagent) does **not** count as subagent nesting — the bg
  session is hosted by Claude Code's daemon and runs outside the parent's
  subagent tree, so the depth-≥2 reliability concern does not apply.
  ADR-0012 is not superseded — its concern about subagent nesting still
  motivates the choice not to spawn workers as Task-tool subagents inside
  the Orchestrator session.

- **Subagent Information Propagation (Confidence: Stable)** — the bg session
  prompt is the only channel for the `/goal` condition and the issue
  reference. The cekernel session ID, issue number, worktree path, and env
  profile are still serialized into the prompt, exactly as in v1. The
  CEKERNEL_*-env-via-Bash-prefix pattern is preserved.

- **`/goal` slash command resolution under `--bg`** (Confidence: Evolving) —
  verified empirically in v2.1.153 that a positional `/goal <condition>`
  in the `claude --bg` prompt argument is parsed as a slash command at
  session bootstrap (registering a session-scoped Stop hook with the
  given condition) rather than treated as the session's display name.
  The v2 spawn pattern depends on this contract. If upstream changes
  the behavior — for example, by requiring explicit hook registration
  via a flag, by treating positional `/goal` as data, or by routing
  slash-command parsing through a different initialization path — v2
  spawn breaks silently (the session would start without the goal hook,
  sit idle, and never complete). Watch the Claude Code changelog for
  changes to `/goal`, `--bg`, or session-bootstrap prompt parsing, and
  re-verify the contract on each upgrade.

- **Bash Tool Shell Selection** and **Context Window Limits** are unchanged
  by this ADR.

## Alternatives Considered

### Alternative 1: Keep v1 unchanged

Stay on `claude -p` + FIFO + state machine. No new spawn path.

**Rejected because**: `-p` will adopt `--bare` semantics in a future release
(officially announced in `claude --help`). All current spawn sites
(`wrapper.sh`, `spawn-orchestrator.sh`, `headless.sh`, `runner.sh`) need
explicit context injection regardless. We pay the migration cost without
gaining anything if we stop at v1.

Additionally, this option leaves cekernel maintaining a state machine, FIFO
protocol, and watcher that have direct first-party equivalents in Claude Code.
Rule of Parsimony argues against this.

### Alternative 2: `--bare` migration only (PR #535 path)

Limit the change to making `claude -p` invocations explicit about hooks,
skills, plugins, MCP, and CLAUDE.md (via `--plugin-dir`, `--add-dir`, etc.)
under an opt-in `CEKERNEL_USE_BARE` flag. Do not change the lifecycle.

**Partially adopted**: this work is already in PR #535 and remains correct
as a defensive measure regardless of whether v2 lands. But it does not
address the redundancy with `claude agents` / `claude --bg` / `/goal`. It is
necessary but insufficient.

### Alternative 3: Observability-only migration

Replace `process-status.sh` and `orchctl ps` with a thin wrapper over
`claude agents --json`, but keep `claude -p` as the spawn primitive and keep
the FIFO + state machine.

**Rejected because**: this gives us the dashboard but pays only a fraction of
the maintenance dividend. The state machine and FIFO remain to be
maintained, and the spawn path still bumps into the `-p` future default
change.

### Alternative 4: `claude --bg --exec '<shell-cmd>'` for cron, no LLM spawn

Replace `wrapper.sh`'s `claude -p` invocation with `claude --bg --exec` so
the supervisor manages the cron job. Workers still use `claude -p`.

**Partially relevant**: this is a sub-piece of v2 worth exploring (it could
make `/cron` artifacts visible in `claude agents --json`), but it does not
address Worker/Reviewer. Treat it as a follow-up within the v2 envelope.

### Alternative 5: Drop the Orchestrator entirely

Express the issue-to-merged pipeline as a single `claude --bg
"/goal Issue #N is merged"` and let the agent itself spawn child sessions
internally.

**Rejected because**: cekernel's value-add concentrates in the Orchestrator
role — concurrency limit, priority scheduling, preemption, issue locks,
worktree management, cron integration. None of those are Claude Code
primitives. Collapsing them into a single autonomous agent loses
predictability and is hard to schedule across machines. The thin-coordinator
Orchestrator is the right amount of cekernel-specific glue.

## Consequences

### Positive

- **~853 lines of shell scripts retired** (measured 2026-06-07):
  all of `scripts/process/` (246 lines: `notify-complete.sh`,
  `phase-transition.sh`, `worker-state-write.sh`, `check-signal.sh`,
  `clear-resume-marker.sh`, `create-checkpoint.sh`), ~46% of
  `scripts/orchestrator/` (419 of 902 lines: `watch.sh`, `health-check.sh`,
  `send-signal.sh`, `process-status.sh`), and 188 lines from
  `scripts/shared/` (`worker-state.sh`, `checkpoint-file.sh`). The state
  machine, FIFO IPC, and watcher surface area moves to Claude Code's
  daemon and the `/goal` evaluator
- **Standard tooling for observability** — operators can use `claude agents`,
  `claude logs`, `claude attach`, `claude stop` directly; no need to learn
  `orchctl` for basic inspection (`orchctl` becomes a join layer on top)
- **Future-proof against `-p` becoming `--bare`** — v2 sessions specify all
  context explicitly via `--plugin-dir`, `--add-dir`, `--agent`, and the
  prompt; the `-p` default change is a non-event
- **Native session IDs** — `claude --bg` returns a UUID, removing the
  glob-and-mtime heuristic in `transcript-locator.sh` (ADR-0013 simplifies)
- **Plan/result audit trail preserved** — verified by PoC: `cekernel:worker`
  still posts `## Execution Plan` and `## Result` issue comments in
  bg+goal mode
- **`/postmortem` works unchanged** — verified on transcripts from both
  PoCs; the transcript-locator's worktree path heuristic correctly resolves
  bg session JSONLs
- **OAuth-friendly** — bg sessions read macOS keychain (verified with
  `env -i HOME PATH ... claude agents --json`); the `--bare` auth blocker
  does not apply

### Negative

- **Daemon lifetime is short under v2.1.153**: the `claude daemon` supervisor
  exits 5 s after the last client disconnects. This is incompatible with
  `/cron`-triggered batches that fire at minute granularity, because each
  cron firing would cold-start a fresh daemon (paying auth-handshake cost
  and risking auth races during burst scheduling). The decision adopts the
  following handling: `/cron`-triggered runners that use `bg-goal` mode
  must **either** cold-spawn the daemon per firing (default; acceptable
  cost at typical schedules) **or** opt into a cekernel-managed
  `claude daemon run` keepalive process (registered alongside the cron job
  in `wrapper.sh`) for high-frequency or auth-sensitive workloads. The
  knob is `CEKERNEL_DAEMON_KEEPALIVE=on|off` (default `off`). If upstream
  changes the idle exit threshold, revisit
- **Depends on Claude Code primitives marked Evolving** — `--bg`, `claude
  agents`, `claude daemon`, `/goal`, and `--permission-mode auto` are all in
  active development. Behavior may change between versions. v2 paths must
  be feature-detected (`claude --version`-gated) and the legacy path must
  remain functional as a fallback
- **Loss of fine-grained state visibility within a Worker** — v1's phase
  detail (`phase1:implement(red)`, `phase3:ci-waiting`, etc.) goes away in
  v2. Operators see `busy` / `idle` from `claude agents` and the gh state of
  the PR, but not internal phase. `orchctl logs` (mapping to `claude logs`)
  shows the TUI buffer, which is harder to parse than the structured state
  file
- **Token cost per Worker invocation rises in some cases** — `cekernel:worker`
  cached at ~21K tokens per turn even when the orchestration-protocol
  paragraphs are unused. The agent-definition split (Migration Phase 1)
  closes this gap; Phase 2 (`bg-goal` dispatch) is sequenced **after**
  Phase 1 specifically so that operators never pay the inflated cost in
  production. Until Phase 1 ships, anyone running `bg-goal` mode manually
  pays the full v1 prompt cost
- **`env -i` foot-gun** — operators or downstream tooling that uses `env -i`
  to clear the environment before `claude --bg` will hit silent auth
  failure. v2 documentation must call this out prominently, and `spawn.sh`
  must verify daemon auth before declaring a Worker dead
- **SUSPEND/RESUME story is unspecified for v2** — v1's
  `create-checkpoint.sh` and `phase-transition.sh ... SUSPEND` pattern has
  no direct v2 equivalent yet. `claude stop` + later `claude --resume <uuid>`
  is the closest analog but does not write a markdown checkpoint and does
  not survive log out (the daemon exits after 5 s idle in this version).
  This is acceptable in the short term because v1 SUSPEND/RESUME is
  comparatively rare, but it is a known gap

### Rollback

`CEKERNEL_SPAWN_MODE=legacy` is the rollback knob. Setting it (in
`~/.config/cekernel/envs/default.env`, a project profile, or as an explicit
`export`) restores v1 spawn behavior on the next Worker invocation. No
daemon-side cleanup is required:

- Workers already in flight under `bg-goal` stay in flight; they continue
  to be observed by `claude agents --json` and are wound down through
  `claude stop` or natural `/goal` completion
- New spawns take the legacy path immediately
- Under `legacy`, `--agent worker` resolves to the original `agents/worker.md`
  (unchanged across the v1/v2 split — see Decision item 4), so behavior is
  byte-for-byte equivalent to the pre-split state. `agents/worker-policy.md`
  exists but is not loaded by `legacy`-mode spawns

If a Worker spawned under `bg-goal` is wedged and `CEKERNEL_SPAWN_MODE` is
flipped to `legacy` mid-flight, the operator stops the wedged session
explicitly with `claude stop <uuid>` before the next legacy spawn — there
is no automatic migration of in-flight sessions across modes.

### Trade-offs

- **Rule of Transparency vs Rule of Parsimony**: v1's file-based state
  machine is highly transparent (`cat .state`, read the FIFO) but verbose
  to maintain. v2's daemon-backed state is opaque (the supervisor is a
  long-running process whose internals we do not see) but small to
  maintain. We choose parsimony, accepting reduced transparency. The
  mitigation is to keep transcripts and gh state as the durable audit
  trail; both are file-based and inspectable

- **Rule of Robustness vs Rule of Composition**: v1's protocol is fully
  under our control — if it breaks, we fix it. v2 depends on Claude Code
  primitives that we do not own. Composition is cheaper to build but
  exposes us to upstream behavioral changes. We accept this for the
  retired-script dividend and gate the change behind
  `CEKERNEL_SPAWN_MODE` so the legacy path remains available

- **Rule of Diversity (both paths coexist) vs Rule of Simplicity (one path)**:
  during migration we maintain two spawn paths, which costs simplicity. We
  accept this because the alternative (cutover) would block adoption of v2
  in production. Once v2 is hardened and the legacy path's user count
  approaches zero, the legacy path can be removed in a future ADR

- **Backward compatibility vs Implementation effort**: keeping
  `agents/worker.md` and `agents/reviewer.md` as-is while introducing
  `worker-policy.md` and `reviewer-policy.md` means we maintain four agent
  definitions during migration. We accept this because removing the v1
  agents pre-emptively would break the legacy spawn path

### Migration Phases

The migration is sequenced to limit risk:

1. **Phase 0 — `--bare` defensive layer** (in PR #535): explicit context
   injection under `CEKERNEL_USE_BARE`. Functionally unchanged. Future-proofs
   `-p` independently of v2
2. **Phase 1 — agent-definition split**: introduce
   `agents/worker-policy.md` and `agents/reviewer-policy.md` (each ~3K
   tokens). Existing `worker.md` / `reviewer.md` unchanged; a short header
   comment in each points readers to the policy file. No behavior change.
   **Phase 1 MUST land before Phase 2** — without it, sessions running
   `bg-goal` mode pay the full ~21K-token-per-turn v1 prompt cost (see
   Negative consequences)
3. **Phase 2 — `spawn.sh` dispatch**: add `CEKERNEL_SPAWN_MODE=bg-goal` path
   that invokes `claude --bg --permission-mode auto --plugin-dir <root>
   --add-dir <worktree> --agent <policy-agent> "/goal <condition>"`. Default
   `legacy`. Implement the `env -i`-free spawn pattern
4. **Phase 3 — `orchctl` view layer**: rewrite `orchctl ps` to merge
   `claude agents --json` with cekernel-specific state. `process-status.sh`
   becomes a back-compat wrapper
5. **Phase 4 — Orchestrator coordinator-mode** (gated by Reviewer
   bg+goal PoC): agent definition adjusts to use `claude --bg` for Worker
   spawns and gh state for completion. No FIFO, no `watch.sh`. Reviewer
   spawn flows through the same path. **Blocking dependency**: an empirical
   PoC must demonstrate that a Reviewer bg+goal session correctly posts
   either an `APPROVE` or `CHANGES_REQUESTED` review on a representative
   PR, including the self-review fallback case (PR_AUTHOR == GH_USER →
   `COMMENT` event). Phase 4 must not ship until this PoC succeeds —
   the Worker PoCs (#536/#538) cover only the Worker side
6. **Phase 5 — retire v1 scripts** (separate ADR): trigger conditions
   (all required):
   - Phase 2's `CEKERNEL_SPAWN_MODE` default has been flipped to `bg-goal`
     for at least 60 consecutive days
   - Zero GitHub issues filed in the cekernel repository during that window
     that are root-caused to the legacy spawn path
   - Maintainer ack in the form of a written sign-off on the Phase 5 ADR

   cekernel has no telemetry collection; the signal is the GitHub issue
   tracker plus maintainer judgment. When the trigger conditions hold,
   a follow-up ADR removes the legacy protocol scripts and v1 agent
   definitions. This is a breaking change for any downstream that uses
   `notify-complete.sh` etc. directly, and must be announced via release
   notes.

### Open Questions

These are deliberately left open in this ADR and will be resolved by
follow-up ADRs or implementation work:

- SUSPEND/RESUME equivalence: no direct mapping yet. Either we accept the
  feature gap, or we treat `claude stop` + worktree state preservation
  as a partial replacement and document the rough edges
- Reviewer-as-`isolation: worktree`-subagent (#531): an orthogonal
  optimization. Compatible with v2 (Reviewer could be a bg session, or a
  subagent inside the Orchestrator bg session). Decision deferred

### Subsumed Discussions

- **`/workflows` vs cekernel boundary (#527)** — this ADR **subsumes** the
  spawn-and-observability scope of #527 (cekernel adopts bg-goal for spawn
  and `claude agents --json` for observability; `/workflows` is for
  in-session deterministic fan-outs, cekernel is for cross-session
  persistent issue pipelines). The only residual discussion in #527 is
  whether cekernel-side skills (e.g., `dispatch` priority scoring) should
  internally use `/workflows` to parallelize their own compute. That
  narrower question can be tracked independently of v2 acceptance

## References

- #534 — research issue containing the empirical PoC evidence
- PoC PRs: #537 (Step 1, default Claude), #539 (Step 2, `cekernel:worker`)
- PR #535 — `--bare` defensive layer (Phase 0)
- #527 — `/workflows` boundary discussion (spawn/observability scope
  subsumed by this ADR; see Subsumed Discussions above)
- ADR-0012 — Worker/Reviewer separation (preserved; this ADR does not
  contradict it)
- ADR-0013 — Transcript-based postmortem (simplifies under v2 native
  session IDs)
- ADR-0014 — Two-tier concurrency env vars (preserved; the
  `CEKERNEL_MAX_ORCH_CHILDREN` limit remains Orchestrator-side under v2)
- Claude Code official docs: `claude --help` (--bare, --bg flags),
  `claude agents --help`, `claude daemon --help`, `claude attach --help`
