# ADR-0018: Platform Interface Contracts

## Status

Proposed

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
The module exports semantic predicates:

| Function | Meaning | Backed by (v2.1.201 matrix) |
|----------|---------|------------------------------|
| `bg_is_alive <token>` | session is running or waiting | `status` ∈ {`busy`, `blocked`} |
| `bg_is_blocked <token>` | waiting on a permission dialog | `status` == `blocked` |
| `bg_is_terminal <token>` | session finished or was stopped | `state` ∈ {`done`, `stopped`}, or session absent |
| `bg_result <token>` | terminal detail | echoes `done` / `stopped` / `gone` |

Liveness reads `status`; terminality reads `state`. The observed
(status, state) matrix is documented in the module header and mirrored in
`docs/claude-code-constraints.md`. Consumers (watch, orchctl, wrapper,
registry, gc, backends, issue-lock) migrate to the predicates.

### 2. mock-claude is the executable specification

`tests/helpers/mock-claude.bash` emits the same (status, state) matrix and
is the contract's test double (staleness coupling per ADR-0017: a PR that
updates the constraints-doc matrix MUST update the mock in the same PR).
Contract tests exercise the predicates against every matrix row, including
drift cases (unknown states → fail noisily, Rule of Repair).

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
  new contract.
- CLAUDE.md: add the review criterion.
