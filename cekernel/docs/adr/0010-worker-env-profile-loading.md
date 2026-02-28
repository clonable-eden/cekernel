# ADR-0010: Worker-side environment profile loading

## Status

Proposed

## Context

ADR-0006 established the environment profile system (`load-env.sh`, `CEKERNEL_ENV`, `.env` files) and made a key assertion:

> **No user-configurable environment variable needs to reach the Worker agent.** Therefore, env profiles need only be loaded by the `/orchestrate` skill and the Orchestrator agent.

This assertion was correct at the time — all configurable behavior (backend selection, concurrency limits, timeouts) was Orchestrator-side. Workers inherited only `CEKERNEL_SESSION_ID` for IPC operations.

### The first Worker-side configuration need

Issue #82 identifies the first Worker-side configuration requirement: the CI retry count. The Worker protocol (`worker.md` On Error section) hardcodes "After 3 failures, report and exit." Different issue types benefit from different retry limits:

- **Simple changes** (typo, docs): 1-2 retries may suffice
- **Complex changes** (multi-file refactoring): 3+ retries may be needed

This is a **policy** decision that should not be hardcoded in the Worker protocol. More Worker-side configuration needs are likely to follow as cekernel matures.

### Why not inject individual variables into the prompt?

The Orchestrator currently passes `CEKERNEL_SESSION_ID` to the Worker via the launch prompt:

```
export CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID} &&
```

The naive approach for CI retry count would add another variable:

```
export CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID} && export CEKERNEL_CI_MAX_RETRIES=5 &&
```

This approach does not scale. Each new Worker-side configuration requires modifying `spawn-worker.sh`'s PROMPT construction. With N configurable variables, the prompt accumulates N `export` statements, violating both Rule of Economy (duplicating what `.env` files already express) and Rule of Separation (embedding policy in the launch mechanism).

### Workers can already reach `load-env.sh`

Workers are LLM agents that resolve file paths as part of their normal operation — just as they already locate and execute `notify-complete.sh` without a hardcoded path. `load-env.sh` is in `cekernel/scripts/shared/`, a sibling of the `worker/` directory containing `notify-complete.sh`. The Worker can find it through the same mechanisms it uses for other cekernel scripts.

The `load-env.sh` multi-layer search (Project → Plugin → Environment variables) is also meaningful for Workers — a project might want to override CI retry counts for its specific CI infrastructure.

## Decision

### 1. Propagate `CEKERNEL_ENV` profile name to Workers

`spawn-worker.sh` adds `CEKERNEL_ENV` to the Worker launch prompt, alongside the existing `CEKERNEL_SESSION_ID`:

```
export CEKERNEL_SESSION_ID=${CEKERNEL_SESSION_ID} && export CEKERNEL_ENV=${CEKERNEL_ENV} &&
```

Only the **profile name** is propagated — not individual configuration values. This is the minimal addition: one variable that unlocks the entire profile system for Workers.

### 2. Workers source `load-env.sh` to self-load configuration

When a Worker needs a configurable value, it sources `load-env.sh` via a Bash command. The file is located at `cekernel/scripts/shared/load-env.sh` relative to the plugin or repository root — the same file that `spawn-worker.sh` already sources on the Orchestrator side.

The Worker is an LLM agent that resolves file paths as part of its normal operation (just as it already locates and runs `notify-complete.sh` without a prescribed path). `worker.md` instructs the Worker to source `load-env.sh` and states its location within the `scripts/shared/` directory. The Worker determines the concrete path using whatever method it finds appropriate (codebase search, relative path from known scripts, etc.).

The Worker uses the same `load-env.sh` and the same multi-layer search as the Orchestrator. The profile name (`CEKERNEL_ENV`) selects the same `.env` file on both sides.

**CWD note**: `load-env.sh` searches project profiles via relative path (`.cekernel/envs/`). The Worker should source it from the worktree root directory to ensure project profiles are found correctly.

### 3. Worker protocol references env variables instead of hardcoding

`worker.md` On Error section changes from:

```markdown
4. After 3 failures:
```

To:

```markdown
4. After $CEKERNEL_CI_MAX_RETRIES failures (source load-env.sh to read; default: 3):
```

The Worker reads the value at runtime rather than following a hardcoded instruction. The default (3) preserves current behavior.

### 4. Source timing: once at CI verification entry

The Worker sources `load-env.sh` once when entering the CI verification loop (Phase 3), not at startup or on every retry. This is the earliest point where Worker-side configuration is needed, and ensures the values are available for all subsequent retry decisions.

```
Phase 0 (Plan) → Phase 1 (Implement) → Phase 2 (Create PR) → Phase 3 (CI verify) ← source here
```

### 5. `default.env` includes Worker-side defaults

```
CEKERNEL_CI_MAX_RETRIES=3
```

The env file documents and centralizes the default, even though `worker.md` also states it. The env file is the authoritative source; the markdown default is an intentional fallback — see "Failure mode" below.

### 6. Failure mode: graceful degradation with default

If the Worker fails to source `load-env.sh` (path resolution error, file not found), it falls back to the default value stated in `worker.md` ("default: 3"). This is a deliberate design choice:

- The retry count is not a critical safety parameter — using the default is always a safe behavior
- The Worker is an LLM agent that can interpret the markdown default independently of the shell environment
- The failure is **visible**: `source` failures produce stderr output that appears in Worker logs, enabling diagnosis

This follows the Rule of Repair: the failure is noisy (stderr), but the system continues with a safe default rather than aborting the entire CI verification phase.

### UNIX Philosophy Alignment

> **Rule of Separation**: *"Separate policy from mechanism; separate interfaces from engines."*

The CI retry count is policy ("how many times should we retry?"). The Worker's CI retry loop is mechanism ("check, fix, push, wait"). ADR-0006 already separated Orchestrator policy into `.env` files. This decision extends that separation to Worker policy. The mechanism (`worker.md` retry loop) remains unchanged; the policy moves from hardcoded text to a configurable variable.

> **Rule of Economy**: *"Programmer time is expensive; conserve it in preference to machine time."*

Adding a new Worker-side configuration should require only adding a line to `default.env` and referencing the variable in `worker.md`. It should not require modifying `spawn-worker.sh`'s PROMPT construction, the Orchestrator agent prompt, or the `/orchestrate` skill. The profile-based approach achieves this: `CEKERNEL_ENV` is propagated once, and all future Worker-side variables are loaded automatically.

> **Rule of Representation**: *"Fold knowledge into data so program logic can be stupid and robust."*

The retry count moves from prose in a markdown file to a named variable in a data file (`.env`), read by `load-env.sh`. However, the Worker is an LLM agent, not a traditional program calling `getenv()`. The Worker still interprets `worker.md` instructions to know *when* to source the file and *how* to use the value. What changes is the **value itself** — externalized from hardcoded prose to configurable data. The "program logic" (LLM reasoning about retry strategy) remains, but the policy parameter it operates on is now in data.

## Alternatives Considered

### Alternative: Inject individual variables into the Worker prompt

Pass each Worker-side variable via `export` in the launch prompt:

```
export CEKERNEL_SESSION_ID=... && export CEKERNEL_CI_MAX_RETRIES=5 && export CEKERNEL_CI_TIMEOUT=600 &&
```

Rejected:

> Rule of Economy: *"Programmer time is expensive; conserve it in preference to machine time."*

Each new variable requires modifying `spawn-worker.sh` PROMPT construction, which means modifying both the normal and resume prompt strings, and potentially the Orchestrator and skill prompts that pass parameters. The profile-based approach requires modifying only `default.env` and the consuming `worker.md` section.

> Rule of Separation: *"Separate policy from mechanism."*

The launch prompt is mechanism (how to start a Worker). Configuration values are policy (how the Worker should behave). Mixing them couples mechanism and policy changes.

### Alternative: Workers always use defaults (no profile loading)

Keep `worker.md` defaults as-is and only allow override via pre-set environment variables.

Rejected:

This does not support per-project customization. A project's `.cekernel/envs/default.env` can override CI retry count for its specific CI infrastructure. Without profile loading, projects must document "set CEKERNEL_CI_MAX_RETRIES before running /orchestrate" — an invisible, undiscoverable convention.

### Alternative: Separate Worker profile (`worker.env`)

Create a Worker-specific env file instead of sharing the same profile.

Not pursued:

> Rule of Parsimony: *"Write a big program only when it is clear by demonstration that nothing else will do."*

There is currently one Worker-side variable. Adding a separate file format for a single variable is premature. If Worker configuration grows to require its own namespace, a `worker.env` can be introduced later. For now, shared profiles with `CEKERNEL_CI_*` naming convention provide sufficient separation.

## Amendments to ADR-0006

This decision amends ADR-0006's key observation:

**Before (ADR-0006)**:
> No user-configurable environment variable needs to reach the Worker agent. Therefore, env profiles need only be loaded by the `/orchestrate` skill and the Orchestrator agent.

**After (this ADR)**:
> Worker agents may load env profiles to read Worker-side configuration (e.g., `CEKERNEL_CI_MAX_RETRIES`). The Orchestrator propagates `CEKERNEL_ENV` (profile name) to Workers via the launch prompt. Workers source `load-env.sh` on demand to read configuration values. The multi-layer search order (Project → Plugin → Environment variables) applies equally to Worker-side loading.

The rest of ADR-0006 remains valid: the profile mechanism, loading order, `.env` format, and project override directory are unchanged.

## Implementation Scope

| File | Change |
|------|--------|
| `spawn-worker.sh` | Add `export CEKERNEL_ENV=${CEKERNEL_ENV}` to both PROMPT strings (normal and resume) |
| `worker.md` | On Error section: reference `CEKERNEL_CI_MAX_RETRIES` with `source load-env.sh` instruction, file location hint (`scripts/shared/`), and default value. Source timing: Phase 3 entry |
| `default.env` | Add `CEKERNEL_CI_MAX_RETRIES=3` |
| `envs/README.md` | Add `CEKERNEL_CI_MAX_RETRIES` to the catalog |
| `ADR-0006` | Add amendment cross-reference to this ADR in the Amendments section |

## Consequences

### Positive

- CI retry count becomes configurable per-profile and per-project without changing mechanism code
- Future Worker-side configuration only requires adding variables to `.env` and `worker.md` — no `spawn-worker.sh` changes
- Workers use the same profile system as the Orchestrator — one mechanism for all configuration
- `CEKERNEL_ENV` is the only new variable in the launch prompt — minimal prompt growth

### Negative

- Workers must locate and source `load-env.sh` at runtime (path resolution delegated to the LLM agent)
- `worker.md` instructions become slightly more complex ("source load-env.sh and read variable" vs. "after 3 failures")
- ADR-0006's clean "Workers don't need config" boundary is relaxed

### Trade-offs

**Simplicity vs. extensibility**: Hardcoding "3" in `worker.md` is simpler. But it cannot be changed without modifying the Worker protocol. The profile-based approach adds a small amount of complexity (one `source` command) in exchange for extensibility to all future Worker-side configuration needs. Given that CI retry count is unlikely to be the last Worker-side knob, the extensibility is worth the complexity.

**One profile for both sides vs. separate namespaces**: Sharing profiles between Orchestrator and Worker means a single `default.env` contains both `CEKERNEL_BACKEND=wezterm` (Orchestrator-only) and `CEKERNEL_CI_MAX_RETRIES=3` (Worker-relevant). This is acceptable because env files are small and readable. If the file grows unwieldy, the `CEKERNEL_CI_` prefix provides a natural namespace for future Worker-side extraction.

## References

- Issue: [#82](https://github.com/clonable-eden/glimmer/issues/82) — Make CI retry count configurable
- ADR-0006: [Centralized Environment Variable Catalog and Profiles](./0006-env-var-catalog-and-profiles.md)
- `load-env.sh`: `cekernel/scripts/shared/load-env.sh`
- `worker.md` On Error: `cekernel/agents/worker.md` (line 234-243)
