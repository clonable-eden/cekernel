---
description: "Analyze Orchestrator/Worker/Reviewer transcripts for a given issue to detect problems and propose fixes"
argument-hint: "<issue-number> [issue-number...]"
allowed-tools: Bash, Read, Agent
---

# /postmortem

Analyzes Claude Code conversation transcripts associated with given issues to detect structural problems, protocol deviations, and anti-patterns. Based on [ADR-0013](../../docs/adr/0013-transcript-based-postmortem-analysis.md).

## Usage

```
/postmortem <issue-number> [issue-number...]
```

One or more issue numbers can be specified. Each issue is analyzed independently and results are compiled into a single report. Orchestrator transcripts are discovered via `.spawned` files in the IPC directory (session reverse lookup), or can be skipped if unavailable.

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

Use `transcript-locator.sh` to find all transcripts associated with the issues. **Loop over each issue number** provided in the arguments.

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
ALL_TRANSCRIPTS="${WORKER_TRANSCRIPTS}${WORKER_TRANSCRIPTS:+$'\n'}${ORCHESTRATOR_TRANSCRIPTS}"
```

#### Transcript Identification

Transcripts discovered by each locator function are treated as follows:

**Orchestrator** (`ORCHESTRATOR_TRANSCRIPTS`):
Transcripts found via `transcript_locate_orchestrator_by_issue` are already identified as Orchestrator (session reverse-lookup via IPC `.spawned` files confirms this). No further inspection is needed.

**Worker/Reviewer** (`WORKER_TRANSCRIPTS`):
`transcript_locate_worker` returns both Worker and Reviewer transcripts (they share the same worktree). File names alone cannot distinguish them. Use the first line's `agentSetting` field in the JSONL to identify the type:

```json
{"type":"agent-setting","agentSetting":"reviewer","sessionId":"6fe286bd-..."}
{"type":"agent-setting","agentSetting":"worker","sessionId":"82bbd747-..."}
```

- Found via `transcript_locate_orchestrator_by_issue` → **Orchestrator**
- `agentSetting` contains `worker` → **Worker** (matches both `worker` and `cekernel:worker`)
- `agentSetting` contains `reviewer` → **Reviewer** (matches both `reviewer` and `cekernel:reviewer`)
- `agentSetting` line missing or no match → **unknown** (still analyze; pass as "unknown type transcript" to subagent)

Report what was found:

```
## Transcript Discovery

- Issues: #N, #M, ...
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
${CEKERNEL_SCRIPTS}/../skills/references/postmortem-patterns.md
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
- **Class**: <1 / 2 / 3 / 4 — from the pattern's Class field>
- **Evidence**: <relevant excerpt or description of what was found in the transcript>
- **Location**: <approximate position in the transcript — e.g., "early in session", "during CI retry phase", or line range if known>
- **Recommendation**: <suggested action or fix>
```

### Step 4: Compile Results

After all subagents complete, compile their findings into a unified report. Group findings by their **Class** (root-cause classification):

```
## Post-Mortem Report: Issue #<number> [, #<number>, ...]

### Summary
- Transcripts analyzed: N
- Issues found: N (X critical, Y warning, Z info)
  - Class 1 (cekernel 不備): N
  - Class 2 (プロジェクト CLAUDE.md/ルール): N
  - Class 3 (外部起因): N
  - Class 4 (Claude Code 不備): N

### Class 1: cekernel の動作/設定不備
> Action: cekernel リポジトリへの issue 作成を検討
<list findings with severity, evidence, recommendation>

### Class 2: プロジェクトの CLAUDE.md/ルール不備
> Action: ターゲットリポジトリへの issue 作成を推奨
<list findings with severity, evidence, recommendation>

### Class 3: 外部起因（GitHub API / Anthropic API 等）
> Action: 既知の制約かどうか事例調査
<list findings with severity, evidence, recommendation>

### Class 4: Claude Code 自体の不備
> Action: 既知の制約かどうか事例調査
<list findings with severity, evidence, recommendation>
```

Omit sections for classes with no findings.

Present this report to the user.

### Step 5: Propose Actions by Class (User Approval Required)

After presenting the report, propose actions for each class that has findings.

**Class 1 — cekernel リポジトリへの issue 作成:**
For each actionable Class 1 finding (critical or warning), propose a GitHub issue in cekernel:
```
1. **Title**: <short title>
   **Body**: <description with evidence and suggested fix>
```
Ask the user which issues to create. For approved issues:
```bash
gh issue create --title "<title>" --body "<body>"
```

**Class 2 — ターゲットリポジトリへの issue 作成:**
For each actionable Class 2 finding (critical or warning), propose a GitHub issue in the target repository.
Creating these issues is recommended. Ask the user for approval before proceeding.
```bash
gh issue create --repo <owner>/<repo> --title "<title>" --body "<body>"
```

**Class 3 & 4 — 事例調査:**
For Class 3 (external) and Class 4 (Claude Code) findings, do not propose issue creation.
Instead, summarize the finding as a known constraint:
```
- **Finding**: <pattern name>
  **Status**: 既知の制約 / 要調査
  **Note**: <brief description of what is known and where to track it>
```

**Do not create any issues without explicit user approval.**

Report the created issue numbers back to the user.

## Notes

- Transcript paths depend on Claude Code's internal implementation and may change. All path resolution is centralized in `transcript-locator.sh` (see ADR-0013).
- If a transcript is too large for a single Read call, subagents should use `offset` and `limit` parameters to read in chunks.
- The analysis is opt-in by design (Rule of Economy) — it only runs when the user explicitly requests it.
