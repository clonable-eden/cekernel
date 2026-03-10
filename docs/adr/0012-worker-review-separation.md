# ADR-0012: Separate Review and Merge from Worker Responsibilities

## Status

Proposed

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

Identity separation (e.g., for `require_last_push_approval` enforcement) is the operator's responsibility, not cekernel's. If an operator wants identity-separated review, they configure a second identity via `CEKERNEL_REVIEWER_GH_TOKEN` and adjust their repository's branch ruleset accordingly. cekernel provides the configuration slot but does not require it.

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
| Execution model | Separate terminal session (backend) | Orchestrator subagent (`run_in_background`) |
| Address space | git worktree (isolated copy) | Main working tree (read-only review) |
| Duration | Long (implementation) | Short (review only) |
| Identity | Operator's GitHub credentials | Operator's GitHub credentials (or optional separate token) |
| Tools | Read, Edit, Write, Bash | Bash only (`gh` for review operations) |

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
watch-worker.sh notification received:
  status=ci-passed       → launch Reviewer subagent
  status=merged          → legacy flow (backward compatibility, eventual removal)
  status=failed          → error handling (existing)
  status=cancelled       → SUSPEND handling (existing)

Reviewer result:
  approved (auto_merge=true)  → Orchestrator runs gh pr merge → cleanup-worktree.sh + desktop notification
  approved (auto_merge=false) → cleanup-worktree.sh + desktop notification (human merges on GitHub)
  changes-requested           → append resume reason to task file
                                → spawn-worker.sh --resume
                                → watch-worker.sh (run_in_background)
                                → on ci-passed → Reviewer re-run
  escalation                  → cleanup-worktree.sh + desktop notification (human intervenes)
```

Retry limit: `CEKERNEL_REVIEW_MAX_RETRIES` (default: 2). After exhaustion, escalate to human via desktop notification.

#### Reviewer Error Handling

The Reviewer subagent can fail in several ways: GitHub API outage, subagent context exhaustion, or unexpected output (neither `approved` nor `changes-requested`). Following the Rule of Repair ("when you must fail, fail noisily and as soon as possible"), all Reviewer failures are treated as escalation:

- Orchestrator receives error or unrecognized result from Reviewer → treat as escalation
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

The concurrency guard in `spawn-worker.sh` counts FIFOs in the IPC directory. When `watch-worker.sh` receives `ci-passed`, it removes the FIFO, freeing the concurrency slot. The worktree persists (for potential re-spawn), but the slot is free for other Workers.

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
| `CEKERNEL_REVIEWER_GH_TOKEN` | (unset) | Optional: separate GitHub token for Reviewer identity separation. When unset, Reviewer uses the operator's `gh` authentication |

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

**Subagent execution model** (Confidence: Evolving): The Reviewer runs as an Orchestrator subagent via `run_in_background`. Per the platform constraints document, subagents cannot communicate with the parent during execution — the parent receives only the final output. This is acceptable for the Reviewer because review is a single-shot operation: read diff, submit review, return result. No mid-execution communication is needed.

**Background task reliability** (Confidence: Evolving): The Orchestrator spawns the Reviewer with `run_in_background`. If the background notification is delayed or missed, the Orchestrator's existing polling patterns (used for `watch-worker.sh`) can serve as fallback. However, since the Reviewer is short-lived (review only, no implementation), the risk of missed notifications is lower than for long-running Workers.

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
