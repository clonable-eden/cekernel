---
description: "Analyze Orchestrator/Worker/Reviewer transcripts for a given issue to detect problems and propose fixes"
argument-hint: "<issue-number> [issue-number...]"
allowed-tools: Bash, Read, Agent
---

# /postmortem

Analyzes Claude Code conversation transcripts associated with given issues to detect structural problems, protocol deviations, and anti-patterns (ADR-0013). Each issue is analyzed independently; results are compiled into a single report. Opt-in by design — runs only on explicit user request.

```
/postmortem <issue-number> [issue-number...]
```

Note: In plugin mode, `/cekernel:postmortem` also works.

## Workflow

### Step 0: Detect Namespace and Resolve Paths

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set the script path:
   - `CEKERNEL_NS=local` → `CEKERNEL_SCRIPTS="$(git rev-parse --show-toplevel)/scripts"`
   - `CEKERNEL_NS=plugin` → `CEKERNEL_SCRIPTS="$(dirname "$(which spawn-worker.sh 2>/dev/null)")/../.."/scripts`

### Step 1: Discover Transcripts

All transcript path resolution is centralized in `transcript-locator.sh` (ADR-0013). Loop over each issue number:

```bash
source "${CEKERNEL_SCRIPTS}/shared/load-env.sh"
source "${CEKERNEL_SCRIPTS}/shared/transcript-locator.sh"

WORKER_TRANSCRIPTS=""
ORCHESTRATOR_TRANSCRIPTS=""
for ISSUE in <issue-numbers...>; do
  FOUND=$(transcript_locate_worker "$ISSUE" 2>/dev/null) || true
  WORKER_TRANSCRIPTS="${WORKER_TRANSCRIPTS:+${WORKER_TRANSCRIPTS}$'\n'}${FOUND}"

  FOUND=$(transcript_locate_orchestrator_by_issue "$ISSUE" 2>/dev/null) || true
  ORCHESTRATOR_TRANSCRIPTS="${ORCHESTRATOR_TRANSCRIPTS:+${ORCHESTRATOR_TRANSCRIPTS}$'\n'}${FOUND}"
done
```

Identify each transcript's type:

- Found via `transcript_locate_orchestrator_by_issue` → **Orchestrator** (session reverse-lookup via IPC `.spawned` files; no inspection needed)
- `transcript_locate_worker` returns both Worker and Reviewer transcripts (shared worktree) — distinguish by the first JSONL line's `agentSetting` field: contains `worker` → **Worker**; contains `reviewer` → **Reviewer** (matches namespaced forms too); missing/no match → **unknown** (still analyze, labeled as unknown)

Report the discovery (issues, per-type counts, total, and any missing transcripts with reasons). If no transcripts are found at all, report the failure and stop.

### Step 2: Read Detection Patterns

Read `${CEKERNEL_SCRIPTS}/../skills/references/postmortem-patterns.md` — it defines all detection categories, heuristics, and severities. Its full content goes into each analysis subagent's prompt.

### Step 3: Analyze Transcripts via Subagents

Launch one analysis subagent per transcript with the Agent tool (transcripts routinely exceed 100K tokens — one per transcript is the default, not a fallback). Launch in parallel when multiple transcripts exist.

- **Description**: `"postmortem: analyze <transcript-basename>"`
- **Prompt** (include all of the following):

```
You are analyzing a Claude Code conversation transcript for post-mortem analysis.

## Transcript
Read this file: <absolute-path-to-transcript.jsonl>

The file is a JSONL (one JSON object per line) of conversation messages.
Read in chunks (Read offset/limit) if it is too large for a single call.

## Detection Patterns
<paste the full content of postmortem-patterns.md here>

## Instructions
1. Read through the transcript systematically
2. For each detection pattern, check whether the transcript contains matching evidence
3. If you find a problem matching no existing pattern, still report it — infer the most appropriate Class (1-4) from the root cause
4. Report ALL matches found, not just the first

## Output Format
Report findings as a structured list ("No issues detected." if none). For each finding:
- **Category** / **Pattern** / **Severity** (critical/warning/info) / **Class** (1-4)
- **Evidence**: excerpt or description from the transcript
- **Location**: approximate position (e.g., "during CI retry phase")
- **Recommendation**: suggested action or fix
```

### Step 4: Compile Results

Compile all subagent findings into a unified report grouped by **Class**, and present it to the user. Omit sections for classes with no findings:

```
## Post-Mortem Report: Issue #<number> [, ...]

### Summary
- Transcripts analyzed: N
- Issues found: N (X critical, Y warning, Z info), broken down by Class 1-4

### Class 1: cekernel defects / configuration issues
> Action: consider creating issue(s) in cekernel repository
### Class 2: project CLAUDE.md / rule gaps
> Action: recommend creating issue(s) in target repository
### Class 3: external constraints (GitHub API / Anthropic API etc.)
### Class 4: Claude Code defects
> Class 3/4 Action: investigate whether this is a known constraint
<each section: findings with severity, evidence, recommendation>
```

### Step 5: Propose Actions by Class (User Approval Required)

**Do not create any issues without explicit user approval.**

- **Class 1** (actionable critical/warning): propose GitHub issues in cekernel (title + body with evidence and suggested fix); create approved ones with `gh issue create`
- **Class 2**: same, targeting the target repository (`gh issue create --repo <owner>/<repo> ...`)
- **Class 3 & 4**: no issue creation — summarize each finding as a known constraint / needs-investigation note

Report created issue numbers back to the user.
