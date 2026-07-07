# ADR-0012: Separate Review and Merge from Worker Responsibilities

## Status

Accepted

## Context

Workers currently handle the entire issue lifecycle end-to-end: implementation, PR creation, CI verification, self-approval, and merge. This monolithic lifecycle has a structural flaw — the same agent context that writes the code also evaluates and merges it. There is no quality gate between "code is written" and "code is on main."

### Current State

```
Orchestrator → spawn Worker → [implement → PR → CI → approve → merge] → notify(merged)
```

The Worker implements code, creates a PR, waits for CI, then approves and merges its own PR — all within the same context window. There is no independent evaluation of the code before it reaches main.

### Problem

The core issue is **confirmation bias at the context window level**. The same agent context that wrote the code also evaluates it. This is analogous to a Unix process writing to a file, verifying its own output, and committing the result — all without any external observer.

| Concern | Current State |
|---------|---------------|
| Write access | Worker pushes code |
| Read/review access | Worker reviews its own code (same context window) |
| Merge authorization | Worker merges its own PR |
| Quality gate | None — no independent evaluation before merge |

When cekernel is self-hosted (its own issues resolved via `/orchestrate`), this lack of review becomes a direct quality risk.

## Decision

Split the Worker lifecycle at the CI pass boundary. Workers stop after CI verification; a new Reviewer agent evaluates the code in a separate context window, and the Orchestrator manages the merge decision.

### Design Principle: cekernel Owns No Identity

cekernel is infrastructure — it provides mechanisms, not policy. All GitHub operations (push, review, merge) are performed using the **operator's credentials**. cekernel does not introduce its own GitHub identity (no bot accounts, no GitHub App tokens, no managed secrets).

- Worker uses the operator's `gh` authentication to push code and create PRs
- Reviewer uses the operator's `gh` authentication to submit review comments
- Orchestrator uses the operator's `gh` authentication to merge PRs

Identity separation (e.g., for `require_last_push_approval` enforcement) is the operator's responsibility, not cekernel's. cekernel does not provide identity-switching mechanisms; if an operator needs it, they manage it outside of cekernel.

### New Lifecycle

```
Orchestrator → spawn Worker → [implement → PR → CI] → notify(ci-passed)
                    ↑              ↓
                    |         Orchestrator → Reviewer (subagent, run_in_background)
                    |              ↓
                    |         [review → approve] → Orchestrator merges or notifies human → desktop notification
                    |              or
                    └──────── [review → reject → changes-requested]
                              → Worker re-spawn (--resume) → [fix → push → CI]
                              → Reviewer re-run ...
```

Three roles with distinct responsibilities:

- **Worker**: implementation engine (mechanism) — writes code, pushes, waits for CI
- **Reviewer**: quality gate (policy) — evaluates code in a separate context, approves or rejects
- **Orchestrator**: lifecycle manager (coordination) — spawns Workers, invokes Reviewer, manages merge, cleans up

### OS Analogy Extension

| OS Concept | cekernel (current) | cekernel (proposed) |
|------------|-------------------|---------------------|
| Process | Worker (implement + merge) | Worker (implement only) |
| Access control | None | Reviewer as quality gate |
| Evaluation context | Single (writer = reviewer) | Dual (separate context windows) |
| Audit trail | Self-certified | Independently reviewed |

### Component Changes

#### Worker: Responsibility Reduction

The Worker's lifecycle ends at CI pass:

- **Phase 3** becomes "CI Verification" only — the `phase3:merging` state is removed (amends ADR-0004: `MERGING` state removed from Worker, replaced by `CI_PASSED` as the Worker's final state before Orchestrator takes over)
- **Completion status**: `notify-complete.sh <issue> ci-passed <pr-number>` (new status)
- **Prohibition**: Worker **must not merge**. This is a hard constraint in the agent definition, not a suggestion
- **Prompt update**: `spawn-worker.sh` prompt changes from `"implement → create PR → verify CI → merge"` to `"implement → create PR → verify CI"`
- **Issue lock**: `notify-complete.sh` currently releases the issue lock unconditionally (line 69-73). With `ci-passed`, the lock must **not** be released — the issue is still being processed (Reviewer pending, possible re-spawn). The lock is released only on terminal statuses (`merged`, `failed`, `cancelled`) or by the Orchestrator at the end of the full lifecycle (escalation). This prevents duplicate Workers from being spawned for the same issue between `ci-passed` and re-spawn

#### Worker: Resume After Rejection

When a Worker is re-spawned after a Reviewer reject, it needs to know the context. The Orchestrator appends a resume reason to `.cekernel-task.md` before re-spawning:

```markdown
## Resume Reason: changes-requested

Review comments are on PR #XX. Read them with `gh pr view XX --comments`.
```

The Worker's resume logic checks:

1. `.cekernel-task.md` contains `## Resume Reason: changes-requested` → read PR review comments, fix issues, push, wait for CI
2. `.cekernel-checkpoint.md` exists → SUSPEND resume (existing flow)
3. Neither → fresh start

This reuses the existing task file mechanism (session memory, ADR-0002) rather than introducing a new IPC channel.

#### Reviewer: New Agent

The Reviewer is architecturally distinct from the Worker:

| Aspect | Worker | Reviewer |
|--------|--------|----------|
| Execution model | Separate terminal session (backend) | Independent process via `spawn-reviewer.sh` (spawn + FIFO) |
| Address space | git worktree (isolated copy) | Reuses Worker's worktree via `--resume` (read-only review) |
| Duration | Long (implementation) | Short (review only) |
| Identity | Operator's GitHub credentials | Operator's GitHub credentials |
| Tools | Read, Edit, Write, Bash | Bash only (`gh` for review operations) |
| Communication | FIFO via `notify-complete.sh` | FIFO via `notify-complete.sh` |

The Reviewer's value comes from **context separation**, not identity separation. A separate agent context evaluating code written by another context avoids the confirmation bias inherent in self-review.

Reviewer responsibilities:

1. Read the target repository's CLAUDE.md and referenced documents
2. Read the PR diff (`gh pr diff`) and issue body (intent)
3. Submit review via `gh pr review`
4. On approve: `gh pr review --approve` → return `approved` to the Orchestrator
5. On reject: `gh pr review --request-changes` → return `changes-requested` to the Orchestrator

The Reviewer does **not** merge. Merge is a lifecycle operation managed by the Orchestrator based on the `CEKERNEL_AUTO_MERGE` setting. This separation ensures the Reviewer remains a pure policy evaluator (Rule of Separation).

The Reviewer does **not** need a worktree because it does not modify files — it only reads diffs and submits reviews via the GitHub API.

#### Orchestrator: Workflow Extension

The Orchestrator gains a new phase between Worker completion and cleanup:

```
watch.sh notification received (Worker):
  status=ci-passed       → spawn Reviewer via spawn-reviewer.sh + watch.sh
  status=merged          → legacy flow (backward compatibility, eventual removal)
  status=failed          → error handling (existing)
  status=cancelled       → SUSPEND handling (existing)

watch.sh notification received (Reviewer):
  result=approved (auto_merge=true)  → Orchestrator runs gh pr merge → cleanup-worktree.sh + desktop notification
  result=approved (auto_merge=false) → cleanup-worktree.sh + desktop notification (human merges on GitHub)
  result=changes-requested           → append resume reason to task file
                                       → spawn-worker.sh --resume
                                       → watch.sh (run_in_background)
                                       → on ci-passed → Reviewer re-run
  result=failed / escalation         → cleanup-worktree.sh + desktop notification (human intervenes)
```

Retry limit: `CEKERNEL_REVIEW_MAX_RETRIES` (default: 2). After exhaustion, escalate to human via desktop notification.

#### Reviewer Error Handling

The Reviewer process can fail in several ways: GitHub API outage, process crash, or unexpected output (neither `approved` nor `changes-requested`). Following the Rule of Repair ("when you must fail, fail noisily and as soon as possible"), all Reviewer failures are treated as escalation:

- Orchestrator receives `failed` status or unrecognized result from Reviewer FIFO → treat as escalation
- Desktop notification sent to human with error details
- Worktree cleaned up (branch and PR exist on remote for human action)
- Issue lock released by Orchestrator

This avoids silent failure modes and ensures a human is always notified when the automated flow cannot complete.

#### Worktree Lifetime

The introduction of a review phase changes when worktree cleanup can occur. Currently, the Worker notifies `merged` and the Orchestrator cleans up immediately. In the proposed flow, the worktree must be preserved longer because the reject → re-spawn cycle reuses it via `spawn-worker.sh --resume`.

The Reviewer runs as an Orchestrator subagent, so its result is returned directly to the Orchestrator — there is no need to monitor the PR merge externally.

| State | Cleanup? | Reason |
|-------|----------|--------|
| Worker `ci-passed` | **No** | Reviewer may reject → Worker re-spawn needs the worktree |
| `changes-requested` → Worker re-spawned | **No** | Worker is actively using the worktree |
| Reviewer approved → Orchestrator merged | **Yes** | Lifecycle complete |
| Reviewer approved (auto_merge=false) | **Yes** | Branch and PR exist on remote; local worktree is no longer needed |
| Reject retry limit exceeded (escalation) | **Yes** | Automated flow is complete; branch and PR exist on remote for human action |

In the `auto_merge=false` and escalation cases, the Orchestrator cleans up the local worktree immediately upon receiving the Reviewer's result. The branch remains on the remote and the PR remains on GitHub for human action. Remote branch deletion is handled by `gh pr merge --delete-branch` (when the human merges) or the repository's auto-delete branch setting.

If a human later requests additional changes on an approved-but-not-merged PR, the automated flow has already concluded. The human can either fix it directly or re-run `/orchestrate` to spawn a new Worker with a fresh worktree.

#### Concurrency Slot Behavior

The concurrency guard in `spawn-worker.sh` counts FIFOs in the IPC directory. When `watch-worker.sh` (now `watch.sh`) receives `ci-passed`, it removes the FIFO, freeing the concurrency slot. The worktree persists (for potential re-spawn), but the slot is free for other Workers.

If the Reviewer rejects and the Worker is re-spawned via `spawn-worker.sh --resume`, a new FIFO is created, consuming a slot. This means the Worker only holds a concurrency slot while actively running — between `ci-passed` and any re-spawn decision, the slot is available for other Workers. This is the correct behavior: review is a lightweight subagent operation that should not block Worker slots.

#### Desktop Notifications

Extract the existing OS-native notification pattern from `scheduler/wrapper.sh:65-73` into a shared helper:

```bash
# scripts/shared/desktop-notify.sh
# desktop_notify <title> <message>
# macOS: osascript -e 'display notification "..." with title "..."'
# Linux: notify-send "..." "..."
```

Refactor `wrapper.sh` to use the shared helper. New notification triggers:

- Reviewer approved → Orchestrator merged
- Reviewer escalation (reject retry limit exceeded)
- Reviewer approved with `CEKERNEL_AUTO_MERGE=false` (human merge needed)

#### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CEKERNEL_AUTO_MERGE` | `false` | `true`: Orchestrator merges after Reviewer approval; `false`: human merges |
| `CEKERNEL_REVIEW_MAX_RETRIES` | `2` | Max reject → re-implement cycles before escalation |

#### State Machine

```
Current:
  NEW → READY → RUNNING(implement) → RUNNING(create-pr)
    → WAITING(ci-waiting) → RUNNING(ci-fixing) → RUNNING(merging) → TERMINATED(merged)

Proposed:
  NEW → READY → RUNNING(implement) → RUNNING(create-pr)
    → WAITING(ci-waiting) → RUNNING(ci-fixing) → TERMINATED(ci-passed)
    → [Reviewer] → TERMINATED(merged) or → Worker re-spawn (--resume)
```

`TERMINATED(ci-passed)` is a new terminal state for the Worker process. The transition from `ci-passed` to `merged` (or back to `RUNNING` via re-spawn) is managed by the Orchestrator, not the Worker.

### UNIX Philosophy Alignment

> **Rule of Separation**: "Separate policy from mechanism; separate interfaces from engines."

The Worker is a mechanism (implementation engine). Review policy (what constitutes acceptable code) is separated into the Reviewer agent. Merge policy (whether to auto-merge after approval) is separated into the Orchestrator via `CEKERNEL_AUTO_MERGE`. The Worker does not need to know review or merge policy; it just implements and signals completion.

> **Rule of Modularity**: "Write simple parts connected by clean interfaces."

The current Worker is a monolith that implements, reviews, and merges. The proposal splits this into three focused components connected by clean interfaces (the `ci-passed` and `approved`/`changes-requested` statuses). Each component has a single responsibility: Worker writes code, Reviewer evaluates code, Orchestrator manages the lifecycle including merge.

> **Rule of Composition**: "Design programs to be connected with other programs."

The Reviewer is composable — it can be replaced with human review, a different AI reviewer, or a hybrid without changing the Worker or Orchestrator. The `ci-passed` → review → `merged`/`changes-requested` interface is the composition point.

> **Rule of Transparency**: "Design for visibility to make inspection and debugging easier."

Adding a review step creates an explicit audit trail. Every merge is preceded by a review comment on the PR, visible in the PR timeline. The `changes-requested` → `re-implement` cycle is also visible in issue comments.

> **Rule of Least Surprise**: "In interface design, always do the least surprising thing."

Developers expect code review before merge. The current auto-merge-without-review behavior is surprising. The proposed flow matches the convention of any team-based development workflow.

### Platform Constraints

**Subagent nesting limitation** (obsolete as of Claude Code v2.1.172; see Amendment 2): At the time of this decision, Claude Code did not support deeply nested subagent hierarchies reliably. When the `/orchestrate` skill launched the Orchestrator as a subagent, and the Orchestrator then attempted to launch the Reviewer as a further nested subagent, the nesting depth could cause reliability issues. This constraint led to the adoption of the spawn + FIFO pattern for the Reviewer (Amendment 1 below). Nested subagents have since become officially supported (fixed depth limit: 5), which is one of the two premises behind Amendment 2.

### Amendment: Spawn + FIFO Pattern for Reviewer (2026-03)

The original design proposed running the Reviewer as an Orchestrator subagent via the `Agent` tool with `run_in_background`. In practice, this creates a subagent nesting problem:

```
/orchestrate skill → Task(orchestrator) → Agent(reviewer)
```

The Orchestrator itself runs as a subagent of the `/orchestrate` skill. Spawning the Reviewer as a further nested subagent hits Claude Code's subagent nesting limitations, which can cause reliability issues and context exhaustion.

**Resolution**: The Reviewer now uses the same spawn + FIFO pattern as Workers:

```
/orchestrate skill → Task(orchestrator) → spawn-reviewer.sh → FIFO notification
```

The Orchestrator spawns the Reviewer as an independent process via `spawn-reviewer.sh` (a wrapper for `spawn.sh --agent reviewer`). The Reviewer communicates its result (`approved`, `changes-requested`, or `failed`) back to the Orchestrator via `notify-complete.sh`, which writes to a FIFO. The Orchestrator monitors this via `watch.sh`, following the same pattern used for Workers.

**Changes from original design**:

| Aspect | Original (subagent) | Amended (spawn + FIFO) |
|--------|---------------------|------------------------|
| Execution model | `Agent(reviewer)` subagent | Independent process via `spawn-reviewer.sh` |
| Communication | Subagent return value | FIFO via `notify-complete.sh` |
| Orchestrator tools | `Agent(reviewer)` in tools list | Bash only (no Agent tool needed) |
| Nesting depth | 3 levels (skill → orchestrator → reviewer) | 2 levels (skill → orchestrator) + independent process |
| Monitoring | Subagent `run_in_background` | `watch.sh` with `run_in_background` |

The Reviewer's core responsibilities (read diff, evaluate, submit review) remain unchanged. Only the execution and communication model changed.

**Impact on other components**:

- `agents/orchestrator.md`: `Agent(reviewer)` removed from tools; Reviewer Phase uses `spawn-reviewer.sh` + `watch.sh`
- `agents/reviewer.md`: Output via `notify-complete.sh` instead of return value
- `skills/orchestrate/SKILL.md`, `skills/dispatch/SKILL.md`: Reviewer launch instructions updated to spawn-based
- `docs/claude-code-constraints.md`: Subagent nesting limitation documented

### Amendment 2: Reviewer as an Orchestrator Subagent with `isolation: worktree` (2026-07)

The 2026-03 amendment adopted the spawn + FIFO pattern because subagent
nesting was unreliable. Two changes have invalidated that premise (#531):

1. **The Orchestrator is no longer a nested subagent.** Since orchestrators
   became independent processes (`spawn-orchestrator.sh` runs
   `claude -p --agent orchestrator`; ADR-0016 moves this to `claude --bg`),
   the Orchestrator is a session **main thread**. A Reviewer spawned via the
   `Agent` tool is depth 1 — the depth-3 chain
   (`skill → Task(orchestrator) → Agent(reviewer)`) no longer exists.
2. **Nested subagents are now officially supported.** As of Claude Code
   v2.1.172, a subagent can spawn its own subagents (fixed depth limit: 5).
   The "nesting depth ≥ 2 is unreliable" constraint is obsolete.

Additionally, subagent frontmatter now supports `isolation: worktree`
(worktree branched from the default branch by default; `worktree.baseRef`
setting can select the parent `HEAD`; auto-removed when the subagent makes
no changes).

**Empirical verification (claude v2.1.201, 2026-07-06):**

- A subagent spawned with `isolation: worktree` from a parent session on
  `2.0-dev` received a worktree at `.claude/worktrees/agent-<id>` branched
  from the **default branch** (`main`), confirming the documented default.
- The worktree contains a full repo copy including `CLAUDE.md`; relative
  symlinks under `.claude/rules/` are copied as-is.
- A main-thread agent (`claude --agent`) can restrict spawnable subagent
  types with `Agent(agent_type)` allowlist syntax in `tools`.

**Resolution**: The Reviewer becomes an Orchestrator **subagent** with
`isolation: worktree`. The Worker remains an independent process (`--bg`
per ADR-0016) because it needs cross-session persistence, which subagents
cannot provide.

```
Orchestrator (main thread, --bg) → Agent(reviewer, isolation: worktree)
                                      ↓ gh pr checkout <N> --detach
                                   [review → gh pr review] → return value
```

**Detached checkout is mandatory, not stylistic.** The PR branch is already
checked out in the Worker's worktree — the Worktree Lifetime table above
deliberately keeps that worktree alive at `ci-passed` for the reject →
re-spawn path — and git forbids checking out the same branch in two
worktrees simultaneously. A plain `gh pr checkout <N>` would therefore
fail on every review. The Reviewer uses `gh pr checkout <N> --detach`
(flag verified present in gh CLI, 2026-07-06), with the flag-independent
equivalent as fallback:

```bash
git fetch origin "pull/<N>/head" && git checkout --detach FETCH_HEAD
```

**Changes from Amendment 1 (spawn + FIFO)**:

| Aspect | Amendment 1 (spawn + FIFO) | Amendment 2 (subagent) |
|--------|----------------------------|------------------------|
| Execution model | Independent process via `spawn-reviewer.sh` | `Agent(reviewer)` subagent of the Orchestrator |
| Address space | Reuses Worker's worktree | Own temporary worktree (`isolation: worktree`), detached PR checkout inside it (see above) |
| Communication | FIFO via `notify-complete.sh` | Subagent return value (`approved` / `changes-requested` / `failed`) |
| Orchestrator tools | Bash only | Bash + `Agent(reviewer)` |
| Diff access | `gh pr diff` (truncation issues, see #521) | Full local checkout — reads files directly |
| Monitoring | `watch.sh` FIFO loop | **Foreground** Agent call (see below) |
| Cleanup | `cleanup-worktree.sh` consideration | Automatic (worktree removed when unchanged; Reviewer never edits — verify the post-checkout "unchanged" assumption, see verification items) |

**Monitoring is foreground, serialization accepted.** A foreground Agent
call blocks the Orchestrator for the duration of the review (minutes), so
under concurrent issues reviews serialize. This is chosen deliberately:
background subagent notifications are cooperative with known
delay/loss issues (`docs/claude-code-constraints.md` § Background Tasks,
Confidence: Evolving), while reviews are short and the Orchestrator's
Worker FIFO events are buffered in the FIFO, not lost, during the block.
Simplicity wins (Rule of Simplicity); revisit only if review throughput
becomes a measured bottleneck.

**Benefits**:

- `spawn-reviewer.sh`, Reviewer FIFO handling, and Reviewer transcript
  tracking are retired — less mechanism (Rule of Parsimony).
- The Reviewer reads the PR branch from a full local checkout, eliminating
  the `gh pr diff` truncation → redundant-read loop (#521).
- Reviewer result delivery becomes synchronous with a **structured return
  contract** — the Reviewer's final output line is exactly one of
  `approved` / `changes-requested` / `failed` — instead of a parsed FIFO
  line. This is still string interpretation, not type enforcement; the
  existing rule in § Reviewer Error Handling applies unchanged to the new
  channel: an unrecognized return value is treated as escalation (Rule of
  Repair: process failures additionally surface as Agent tool errors).

**Trade-offs**:

- The Reviewer's lifetime is bound to the Orchestrator session. Reviews are
  short (minutes), and the Orchestrator already outlives the review window
  in the monitoring loop, so this is acceptable.
- Requires Claude Code ≥ v2.1.172 (nested subagents) — effectively pinned
  higher by ADR-0016's `--bg` requirements. 2.0.0 is a breaking release
  (ADR-0016): the subagent Reviewer fully replaces the spawned one; users
  needing the old model stay on the 1.x line.

**Impacted components** (implementation issues to follow):

- `agents/orchestrator.md`: add `Agent(reviewer)` to `tools`; Reviewer phase
  uses the Agent tool instead of `spawn-reviewer.sh` + `watch.sh`
- `agents/reviewer.md`: frontmatter gains `isolation: worktree` **and
  `Read` in `tools`** (local file reads replace `gh pr diff`); FIFO
  notification instructions replaced by the return contract (final output
  line is exactly one of `approved` / `changes-requested` / `failed` —
  and nothing after it); diff reading switches to detached PR checkout +
  local file reads. The diff procedure must fetch the PR's **base ref**
  explicitly and compare against the merge-base — `git fetch origin
  <base>` then `git diff origin/<base>...HEAD` — because the worktree is
  created from the default branch while the PR base may be a non-default
  branch (e.g. `2.0-dev`), and the worktree's `origin/<base>` is only as
  fresh as the last fetch
- Permissions: the Reviewer inherits the parent's tool permissions.
  `gh pr review` (and the checkout commands) must be pre-authorized in the
  Orchestrator's context, or the review stalls exactly like ADR-0016's
  `blocked` state — ADR-0016's supervision requirements apply to the
  Orchestrator session that hosts the Reviewer
- `scripts/orchestrator/spawn-reviewer.sh`: removed in 2.0.0 (breaking
  change, ADR-0016), together with its tests
- `docs/claude-code-constraints.md` and `CLAUDE.md`: the subagent-nesting
  constraint must be rewritten (obsolete as of v2.1.172)
- Tests: reviewer spawn tests re-target the new orchestration contract

**Verification items for the implementation issue** (unverified platform
assumptions; CLAUDE.md feasibility-check rule applies):

1. Worktree auto-cleanup after a detached checkout: confirm that fetching
   and moving HEAD still counts as "unchanged" for the auto-removal of
   `.claude/worktrees/agent-<id>` (only a dirty working tree should count
   as a change). If not, the Orchestrator needs an explicit cleanup step.
2. `.claude/worktrees/` hygiene: main-tree `git status` was observed clean
   after a subagent worktree PoC (2026-07-06) despite no project
   `.gitignore` entry — confirm the ignore mechanism so it doesn't
   silently regress.
3. Symlink behavior in the full checkout: `.claude/rules/` relative
   symlinks may actually resolve inside an agent worktree (unlike the bare
   assumption recorded in CLAUDE.md); re-verify when rewriting the
   nesting/worktree constraints (non-blocking).

**Verification results (2026-07-06, #551 implementation; claude v2.1.201):**

1. **Auto-cleanup after detached checkout: confirmed safe.** The removal
   routine (`removeAgentWorktree`, inspected in the v2.1.201 binary) aborts
   only when `git status --porcelain` reports a dirty working tree. Fetches
   and HEAD movement (detached checkout) leave porcelain output empty, so a
   read-only Reviewer worktree is auto-removed. No explicit Orchestrator
   cleanup step is needed.
2. **`.claude/worktrees/` ignore mechanism: identified.** On agent-worktree
   creation, Claude Code appends `**/.claude/worktrees/` (and other runtime
   paths) to the repository's `.git/info/exclude` under a
   `# claude-code-runtime` marker (`ensureClaudeRuntimeFilesExcluded`). No
   project `.gitignore` entry is required, and the mechanism is per-clone —
   a fresh clone regains it on first agent-worktree creation.
3. **Symlinks resolve: confirmed.** `.claude/rules/` relative symlinks
   (`../../docs/*.md`) resolve correctly inside a full worktree checkout
   (verified by reading through them in a live worktree). The stale
   CLAUDE.md note was corrected; the extracted Review section in CLAUDE.md
   is retained because rules auto-loading inside agent worktrees is still
   not guaranteed.

### Amendment 3: `CEKERNEL_KEEP_WORKTREE` — Optional Worktree Retention After Approval (2026-07)

The Worktree Lifetime table above mandates immediate worktree removal on
Reviewer approval, including the `auto_merge=false` case ("local worktree is
no longer needed"). Operational experience showed this assumption does not
hold for `CEKERNEL_AUTO_MERGE=false` deployments: humans often want to run
final verification or extra manual steps in the existing worktree before
merging, and recreating it via `git worktree add` loses the checkpoint and
task files (#524).

`CEKERNEL_KEEP_WORKTREE` (default: `false`) is added to opt out of worktree
removal. It is read by `cleanup-worktree.sh` itself rather than decided by
the Orchestrator agent, keeping the behavior deterministic (Rule of
Separation: the env var is policy, the script is mechanism). When `true`:

- The Worker process is still killed and all IPC resources (FIFO, state,
  handle files) are still removed — FIFOs feed the concurrency guard, so
  keeping them would leak scheduling slots
- The worktree and its local branch are preserved; checkpoint and task
  files inside the worktree survive
- `--force` overrides the setting and always removes the worktree, so the
  zombie-recovery path (`cleanup-worktree.sh --force`) keeps freeing the
  worktree for a fresh spawn

The default (`false`) preserves the original behavior in this ADR. Humans
who keep worktrees are responsible for removing them eventually
(`git worktree remove`).

### Amendment 4: Permission Portability — Surface Gaps, Don't Resolve (2026-07)

A cross-transcript postmortem of 24 self-hosted PRs (2026-07-07) found the
Worker permission surface is three layers (see
`docs/claude-code-constraints.md` § Permission Model): (1) the target
repo's `settings.json` allowlist, (2) a safety classifier that rejects
dangerous patterns even when layer 1 allows a tool broadly (mechanism
unconfirmed — supervisor-inherited vs headless-intrinsic), (3) silent
`blocked` / denial when the first two are not satisfied.

Every self-hosted Worker completed only because cekernel's own settings
and the runtime classifier happened to align. This is **not portable**: a
target repo without a Worker allowlist strands the Worker at layer 3 as a
silent `blocked` — the failure ADR-0012's "delegate to the operator"
principle does not cover. It is that principle's blind spot: delegating is
correct, but breaking *silently* when the delegated prerequisite is absent
violates the Rule of Repair.

**Decision** — cekernel surfaces the gap early but does **not** resolve
permissions (it cannot: there is no platform query API, only bypass flags):

1. **Coarse spawn preflight (full resolution is a Non-Goal).** `spawn.sh`
   checks only that the target repo has a `.claude/settings.json` with a
   non-empty `permissions.allow`; if not, it emits a **noisy warning**
   (example allowlist, or the `--permission-mode acceptEdits` escape) and
   proceeds. Per-tool permit/deny is left to the platform and caught at
   layer 3 via `bg_is_blocked` (ADR-0018). Reimplementing the platform's
   resolution engine — settings hierarchy, `Bash(cmd)` glob semantics,
   the classifier — is explicitly rejected: it would produce a *worse*
   failure (preflight passes yet the Worker blocks, or false-fails) than
   the gap it closes.
2. **Layer 2 recorded as Evolving, mechanism unconfirmed.** No inheritance
   claim is asserted. A minimal experiment (auto-mode vs non-auto
   supervisor → does the Worker's classifier behavior change?) is a
   verification item, foldable into #587.
3. **Worker keeps avoidance-first on denial.** On a classifier denial the
   Worker first attempts a workaround (as in `#543`, which fell back from
   `bats` to a `ruby` check and still reached ci-passed); only when no
   workaround exists does it surface `blocked`. Forcing an immediate
   `blocked` on every denial is rejected — it would kill that good
   behavior.
4. **`bypassPermissions` is not made the default.** Papering over the gap
   with a blanket bypass maximizes blast radius under autonomous (goal)
   loops. The `blocked` surface (ADR-0018 `bg_is_blocked`) stays the
   safety net; the "denial → workaround vs stop" policy for goal loops is
   deferred to a goal-design ADR.

**Non-Goals**: reimplementing the platform permission engine; per-call
pre-spawn permit decisions; controlling or bypassing the layer-2
classifier.

**Scope**: the coarse preflight (Decision 1) and the setup-skill allowlist
guidance are 2.0-sized. Layer-2 verification and goal-loop permission
policy are post-2.0 (v2.1). **2.0 release is not blocked on this
Amendment.**

### Amendment 5: Reviewer Subagent Grant Must Be Namespace-Agnostic (2026-07-07)

Amendment 2 is **kept** — the Reviewer stays an Orchestrator subagent. But
its first plugin-mode run (#600) exposed a latent defect: the Orchestrator's
`tools: ... Agent(reviewer)` allowlist only permits the bare name `reviewer`.
That name exists in **local** self-hosting (`.claude/agents/reviewer.md`), so
23 spawns succeeded during the Waves; under **plugin** distribution the
Reviewer is the namespaced `cekernel:reviewer`, which `Agent(reviewer)`
silently blocks (the Agent tool reports "not found" with an empty available
list). The Orchestrator then improvised a self-review via `gh pr review
--approve` — which fails on an author's own PR — and still sent an `approved`
notification (a Rule of Repair violation: success reported on a broken state).

The grant was itself a fossil: it was added 2026-03 for the *first* subagent
attempt, went vestigial when Amendment 1 moved the Reviewer to spawn + FIFO,
and was silently reactivated by Amendment 2 (2026-07) without updating for
plugin namespacing. Live testing confirmed plugin agents **can** be
subagents (a `--plugin-dir` session spawned `cekernel:probe`); the sole
cause was the grant name.

**Decision**: grant the Orchestrator unrestricted `Agent` (no parentheses),
which permits the subagent under either namespace. Plugin-namespaced
allowlist entries (`Agent(cekernel:reviewer)`) are undocumented, so an
allowlist is not a reliable cross-mode option; the Orchestrator is
first-party and spawns Workers as processes (not subagents), so dropping the
allowlist costs nothing. The Orchestrator must **never review the PR itself**
and must gate the `approved` notification on the Reviewer's actual verdict
(orchestrator.md). The durable lesson — verify feasibility in both local and
plugin modes — is recorded in CLAUDE.md (Design Decisions).

## Alternatives Considered

### Alternative: Human-Only Review

All PRs require human review. No Reviewer agent.

- **Pro**: Maximum quality assurance, full human judgment
- **Con**: Violates the Rule of Economy — "Programmer time is expensive; conserve it in preference to machine time." For routine, well-scoped issues (the majority of cekernel's self-hosted work), human review is bottleneck overhead
- **Con**: Breaks the autonomous pipeline that makes `/orchestrate` valuable
- **Rejected**: Does not scale. Suitable as a deployment choice (`CEKERNEL_AUTO_MERGE=false`) but not as the only option

### Alternative: Worker Self-Review with Separate Pass

The Worker performs a second pass on its own code before merging, acting as both author and reviewer.

- **Pro**: No new agent needed, simpler architecture
- **Con**: Violates Rule of Separation — policy (review) and mechanism (implementation) remain coupled in the same process
- **Con**: Confirmation bias — the same context window that wrote the code is unlikely to catch its own mistakes
- **Rejected**: Does not address the fundamental problem of same-context self-review

## Consequences

### Positive

- **Quality gate**: Every merge is preceded by an independent review from a separate agent context, reducing confirmation bias
- **Audit trail**: PR timeline shows review comments before merge, providing visibility into what was evaluated
- **Composability**: Review strategy is swappable — automated, human, or hybrid — without changing Worker or Orchestrator core logic
- **Principle of least privilege**: Worker loses merge authority, reducing the blast radius of a malfunctioning Worker
- **Backward compatible**: `status=merged` remains valid for legacy/transitional use; the Orchestrator handles both flows
- **No secret management**: Default configuration requires no additional tokens or credentials — operates entirely on the operator's existing `gh` authentication

### Negative

- **Increased latency**: The review step adds time between CI pass and merge. For small, routine changes, this overhead may feel unnecessary
- **New component**: The Reviewer agent is a new moving part that must be maintained, tested, and monitored
- **Retry complexity**: The reject → re-implement → re-review cycle adds state management complexity to the Orchestrator

### Trade-offs

**Autonomy vs. safety**: The current Worker is maximally autonomous — it can resolve an issue end-to-end without any human or external intervention. This proposal sacrifices some autonomy (Worker can no longer merge) for safety (independent review gate). The `CEKERNEL_AUTO_MERGE` flag allows tuning this trade-off per deployment.

**Simplicity vs. separation**: Adding a Reviewer agent increases system complexity (Rule of Simplicity tension). However, the three-way separation of implementation (Worker), review (Reviewer), and lifecycle management including merge (Orchestrator) follows the Rule of Separation rigorously — each component handles exactly one concern. The complexity is justified by the quality assurance it provides.

**Latency vs. correctness**: The review step adds wall-clock time to the issue lifecycle. For cekernel's self-hosted development (low volume, high correctness requirements), this is an acceptable trade-off. Environments with different priorities can set `CEKERNEL_AUTO_MERGE=true` to enable automated merge after Reviewer approval.
