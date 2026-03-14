---
description: "Analyze Orchestrator/Worker/Reviewer transcripts for a given issue to detect problems and propose fixes"
argument-hint: "<issue-number>"
allowed-tools: Bash, Read, Agent
---

# /postmortem

Analyzes Claude Code conversation transcripts associated with a given issue to detect structural problems, protocol deviations, and anti-patterns. Based on [ADR-0013](../../docs/adr/0013-transcript-based-postmortem-analysis.md).

## Usage

```
/postmortem <issue-number>
```

The issue number identifies which Worker/Reviewer transcripts to locate. Orchestrator transcripts are discovered via the persisted Claude Code session ID in the IPC directory, or can be skipped if unavailable.

Note: In plugin mode, `/cekernel:postmortem` also works.

## Workflow

### Step 0: Detect Namespace and Resolve Paths

Detect whether cekernel is running as a plugin or locally using file-based detection (ADR-0009).

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set namespace based on the result:
   - If `CEKERNEL_NS=local`: `CEKERNEL_SCRIPTS="$(git rev-parse --show-toplevel)/scripts"`
   - If `CEKERNEL_NS=plugin`: `CEKERNEL_SCRIPTS="$(dirname "$(which spawn-worker.sh 2>/dev/null)")/../.."/scripts`

### Step 1: Discover Transcripts

Use `transcript-locator.sh` to find all transcripts associated with the issue.

```bash
source "${CEKERNEL_SCRIPTS}/shared/transcript-locator.sh"
source "${CEKERNEL_SCRIPTS}/shared/session-id.sh"

# Discover Worker/Reviewer transcripts (always available by issue number)
WORKER_TRANSCRIPTS=$(transcript_locate_worker <issue-number> 2>/dev/null) || true

# Discover Orchestrator transcripts (via IPC-persisted session ID)
ORCH_TRANSCRIPTS=$(transcript_locate_orchestrator_by_ipc 2>/dev/null) || true
```

Report what was found:

```
## Transcript Discovery

- Worker/Reviewer: N transcript(s) found
- Orchestrator: N transcript(s) found
- Total: N transcript(s) to analyze

Missing transcripts (if any):
- <explain what was not found and why>
```

If no transcripts are found at all, report the failure to the user and stop.

### Step 2: Read Detection Patterns

Read the detection patterns checklist:

```
$(git rev-parse --show-toplevel)/skills/references/postmortem-patterns.md
```

This file defines all detection categories, heuristics, and severities. The full content of this file will be included in each analysis subagent's prompt.

### Step 3: Analyze Transcripts via Subagents

For **each** discovered transcript, launch an analysis subagent using the Agent tool. Transcripts routinely exceed 100K+ tokens and cannot fit in a single context window — one subagent per transcript is the expected default, not an edge-case fallback.

Launch subagents in parallel when multiple transcripts exist.

For each subagent:

- **Description**: `"postmortem: analyze <transcript-basename>"`
- **Prompt** (include all of the following):

```
You are analyzing a Claude Code conversation transcript for post-mortem analysis.

## Transcript
Read this file: <absolute-path-to-transcript.jsonl>

The file is a JSONL (one JSON object per line). Each line is a conversation message
(user/assistant turns, tool calls, tool results). Read the file in chunks if it is
too large to read at once (use the offset/limit parameters of the Read tool).

## Detection Patterns
<paste the full content of postmortem-patterns.md here>

## Instructions
1. Read through the transcript systematically
2. For each detection pattern, check whether the transcript contains matching evidence
3. Report ALL matches found, not just the first

## Output Format
Report findings as a structured list. If no problems are found, report "No issues detected."

For each finding:
- **Category**: <pattern category from the checklist>
- **Pattern**: <specific pattern name>
- **Severity**: critical / warning / info
- **Evidence**: <relevant excerpt or description of what was found in the transcript>
- **Location**: <approximate position in the transcript — e.g., "early in session", "during CI retry phase", or line range if known>
- **Recommendation**: <suggested action or fix>
```

### Step 4: Compile Results

After all subagents complete, compile their findings into a unified report:

```
## Post-Mortem Report: Issue #<number>

### Summary
- Transcripts analyzed: N
- Issues found: N (X critical, Y warning, Z info)

### Critical Issues
<list critical findings with evidence>

### Warnings
<list warning findings with evidence>

### Informational
<list info findings>

### Proposed Issues
For each critical or warning finding that is actionable, propose a GitHub issue:
1. **Title**: <short title>
   **Body**: <description with evidence and suggested fix>
2. ...
```

Present this report to the user.

### Step 5: Create Issues (User Approval Required)

After presenting the report, ask the user which proposed issues to create.

**Do not create issues without explicit user approval.**

For each approved issue, create it via:

```bash
gh issue create --title "<title>" --body "<body>"
```

Report the created issue numbers back to the user.

## Notes

- Transcript paths depend on Claude Code's internal implementation and may change. All path resolution is centralized in `transcript-locator.sh` (see ADR-0013).
- If a transcript is too large for a single Read call, subagents should use `offset` and `limit` parameters to read in chunks.
- The analysis is opt-in by design (Rule of Economy) — it only runs when the user explicitly requests it.
