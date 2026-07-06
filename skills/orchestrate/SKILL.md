---
description: Delegate issues to the Orchestrator agent for parallel processing after priority assessment
argument-hint: "[--env profile] <issue-numbers>"
allowed-tools: Bash, Read
---

# /orchestrate

Delegates specified issues to the Orchestrator agent for parallel processing using git worktrees.

## Usage

Receive issue numbers (single or multiple) from the user.

Optional flags:

- `--env <profile>` — Env profile (default: `default`). Available: `default`, `headless`, `ci`, or any custom profile in `.cekernel/envs/`.

```
/orchestrate #108
/orchestrate --env headless #108 #109
/orchestrate https://github.com/org/planning/issues/578
```

Note: In plugin mode, `/cekernel:orchestrate` also works.

### Cross-repo Issue References (#440)

Issue references may be plain numbers (`#108`) or references to another repository (issue URL, `/owner/repo/issues/N` path, or `owner/repo#N`). For each non-plain reference, extract `owner/repo` and the issue number, then compare with the current repository (`git config --get remote.origin.url`):

- **Same repository** → treat as a plain issue number
- **Different repository** → record `owner/repo` as that issue's repo. Pass `--repo <owner/repo>` to issue-related `gh` commands during triage, and include the issue repo in the Orchestrator prompt so it propagates to `spawn-worker.sh --repo`

The working repository (current directory) always hosts the worktrees, branches, and PRs — run `/orchestrate` from the implementation repository, not from the meta-repository hosting the issues.

## Workflow

Read `skills/references/orchestrator-launch.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/orchestrator-launch.md`; if the Read fails, resolve it via `${CLAUDE_SKILL_DIR}/../references/orchestrator-launch.md`) and follow the launch protocol with these skill-specific policies:

1. **Step A** (agent names + script path): as written.
2. **Step B** (lock filter): remove locked issues from the candidate list; report skipped issues.
3. **Triage**: read `skills/references/triage.md` from the same directory and follow the triage protocol for each remaining issue.
4. **Step C** (concurrency guard) — over-limit policy: report the count and limit, then ask the user whether to **wait** or **cancel**. If waiting, poll `orchctl.sh count` every 30 seconds until a slot opens, then proceed. If cancelling, exit without action.
5. **Step D** (session init): as written.
6. **Step E** (prompt + launch): include the base branch and cross-repo issue lines when applicable.
