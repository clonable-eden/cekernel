# ADR-0013: Transcript-Based Post-Mortem Analysis

## Status

Proposed

## Context

The Orchestrator/Worker/Reviewer pipeline can encounter structural problems during execution — IPC directory deletion, agent definition mismatches, protocol deviations, and similar failures. During issue #335 processing, two such problems occurred (#339: test runner deleting production IPC directory, #340: Reviewer launching with Worker agent definition). Both were discovered only after a human manually fed the Orchestrator's 630KB conversation transcript to an agent for analysis.

This manual process should be formalized as a skill (`/postmortem`) to enable reproducible failure analysis.

### Information Source Selection

Three candidates exist for analysis input:

1. **Claude Code conversation transcript** — The conversation log (`.jsonl`) that Claude Code maintains internally. Contains tool calls, results, reasoning, decisions, and retry logic
2. **cekernel IPC logs** — `${CEKERNEL_IPC_DIR}/logs/worker-{issue}.log`. Structured event logs (SPAWN, FIFO_CREATE, etc.) but lacks agent reasoning
3. **stdout/stderr capture** — Removed in #347. Redundant with transcripts; suffered from reliability issues with the `script` command

Transcripts are the richest information source and a superset of the others.

### Trigger Model

Two models exist: automatic (always analyze after pipeline completion) and manual (explicit user request).

Risks of automatic execution:
- Analysis cost (API consumption) on every run, including successful ones
- When installed as a plugin in other repositories, users may not want unsolicited issue creation
- Some users may not want transcript contents to be analyzed (privacy)

## Decision

**Introduce a `/postmortem` skill that takes Claude Code conversation transcripts as input and runs on explicit user request (opt-in).**

### Design

```
/postmortem <issue-number>
```

1. Identify and read Orchestrator/Worker/Reviewer transcripts associated with the given issue
2. Detect problems based on known patterns (see below)
3. Report findings in a structured format
4. Create issues after user approval

### Detection Patterns

| Category | Examples |
|----------|----------|
| IPC/state anomalies | File deletion, FIFO corruption, stale locks |
| Agent mismatch | Worker launched as Reviewer or vice versa |
| Excessive CI retries | Same error causing repeated retries |
| Protocol deviation | Departure from `worker.md` / `reviewer.md` procedures |
| Test isolation failures | Side effects on production environment |
| Script UX issues | Unexpected errors, argument misinterpretation, recovery attempts |

Patterns are maintained as a markdown checklist in `skills/references/postmortem-patterns.md`, keeping the skill logic itself generic — "read transcript, match against patterns." Adding a new detection target means appending to the checklist, not modifying the skill.

### Transcript Storage Locations

Claude Code stores conversation transcripts at the following paths:

| Type | Path |
|------|------|
| Interactive session | `~/.claude/projects/<project>/<session-id>.jsonl` |
| Subagent (Orchestrator, etc.) | `~/.claude/projects/<project>/<session-id>/subagents/agent-<agent-id>.jsonl` |
| Worker / Reviewer | `~/.claude/projects/<worktree-project-path>/<session-id>.jsonl` |

- `<project>` is the working directory path converted to hyphen-delimited form (e.g., `-Users-alice-git-myrepo`)
- Workers and Reviewers run in worktrees, so their transcripts are stored under the worktree's corresponding project directory
### Transcript Discovery Algorithm

Given an issue number, the skill locates all relevant transcripts:

1. **Worker / Reviewer transcripts**: Glob `~/.claude/projects/*-issue-{number}-*/*.jsonl`. Worktree directory names contain the issue number, so this pattern matches directly. Multiple `.jsonl` files may exist if the Worker was re-spawned (resume); all are analyzed.
2. **Orchestrator transcript**: The Orchestrator runs as a subagent of the interactive session. Its transcript is at `~/.claude/projects/<project>/<session-id>/subagents/agent-<agent-id>.jsonl`. Discovery requires the user to provide the session context (e.g., "this session" or a session ID), since there is no filesystem-level link from issue number to Orchestrator subagent.
3. **Absent transcripts**: Worktree cleanup (`cleanup-worktree.sh`) deletes the worktree directory, but the corresponding `~/.claude/projects/` entry persists (it is managed by Claude Code, not cekernel). If transcripts are not found, the skill reports which transcripts are missing and continues with what is available.

Each transcript is delegated to a subagent for analysis, since transcripts routinely exceed 100K+ tokens and cannot fit in a single context window. This is the expected default, not an edge-case fallback.

> **Note**: These paths depend on Claude Code's internal implementation and may change across versions. Path resolution logic is centralized in a `transcript-locator.sh` script so that changes can be absorbed in one place.

### UNIX Philosophy Alignment

> Rule of Composition: "Design programs to be connected with other programs."

Takes transcripts (text streams) as input and produces structured problem reports as output. Both input and output are composable with existing tools (`gh issue create`, other skills).

> Rule of Separation: "Separate policy from mechanism; separate interfaces from engines."

Detection patterns (policy) are separated from the skill's analysis logic (mechanism). Adding new detection targets does not require logic changes.

> Rule of Transparency: "Design for visibility to make inspection and debugging easier."

Problems are explicitly reported rather than silently ignored. This enables cekernel's self-improvement cycle.

> Rule of Economy: "Programmer time is expensive; conserve it in preference to machine time."

Replaces manual analysis of 630KB+ transcripts with automated pattern detection. Humans focus only on the issue-creation decision.

### Platform Constraints

**Context Window Limits** — Large transcripts (630KB+) routinely exceed a single context window. Subagent delegation is the expected default: one subagent per transcript, each performing pattern matching within its own context window.

**Subagent Nesting Limitation** — When `/postmortem` runs as a skill, it can use subagents one level deep. This is sufficient for the design (skill → analysis subagent). Parallel analysis of multiple transcripts is feasible within this single nesting level.

## Alternatives Considered

### Alternative: Automatic Execution (always analyze after pipeline completion)

Run `/postmortem` automatically after every Orchestrator completion.

Rejected because:
- Violates Rule of Economy — cost incurred even on successful runs with no problems
- May conflict with plugin users' intent (unsolicited issue creation, privacy concerns)
- Running only when the user deems it necessary better aligns with Rule of Silence (avoid unnecessary output)

### Alternative: IPC Log-Based Analysis

Use only cekernel's structured IPC logs as the analysis target.

Rejected because:
- IPC logs record event occurrences but not the agent's reasoning, decisions, or retry rationale
- The problems discovered in #335 (#339, #340) were not detectable from IPC logs alone
- Transcripts are a superset of IPC logs; there is no reason to accept less information

### Alternative: Restore stdout/stderr Capture

Revive `script-capture.sh` (removed in #347) to save stdout to files for analysis.

Rejected because:
- A strict subset of transcripts with no additional information
- Reliability issues with the `script` command (terminal dependency, buffering)
- Requires additional instrumentation that transcripts do not

## Consequences

### Positive

- Formalizes cekernel's self-improvement cycle (problem → analysis → issue → fix)
- Eliminates manual transcript analysis, improving reproducibility of failure diagnosis
- Detection patterns accumulate as a knowledge base over time

### Negative

- **Transcript path dependency is the single largest risk.** The entire skill is predicated on locating and reading `.jsonl` files at Claude Code's internal storage paths. If Claude Code changes its storage format or location, the skill breaks completely. Mitigation: centralize path resolution in `transcript-locator.sh` so changes are absorbed in one place
- Large transcript analysis incurs API cost (one subagent per transcript)

### Trade-offs

**Rule of Simplicity vs Rule of Transparency**: Opt-in keeps the mechanism simple but risks missing problems. However, automatic analysis of every run violates Rule of Economy, making opt-in the appropriate balance.

**Rule of Extensibility vs Rule of Parsimony**: Making detection patterns data-extensible may seem excessive for the initial implementation. However, pattern additions will occur continuously through cekernel operations, justifying upfront investment in extensibility.
