---
description: Batch-process open issues with the `ready` label — discover, triage, and delegate to the Orchestrator
argument-hint: "[--yes] [--env profile] [--label label]"
allowed-tools: Bash, Read
---

# /dispatch

Discovers open issues labeled `ready`, triages them, and delegates to the Orchestrator agent for parallel processing.

## Usage

No arguments required — by default, picks up all open issues with the `ready` label.

Optional flags:

- `--yes`, `-y` — Skip the user confirmation step. Required for non-interactive execution (cron, at).
- `--env <profile>` — Env profile (default: `default`). Available: `default`, `headless`, `ci`, or any custom profile in `.cekernel/envs/`.
- `--label <label>` — Override the target label (default: `ready`).

```
/dispatch
/dispatch -y --env headless --label sprint-3
```

Note: In plugin mode, `/cekernel:dispatch` also works.

## Idempotency

- A merged Worker PR closes its issue via `closes #N`
- Discovery uses `--state open`, so closed issues are excluded on the next run
- No label manipulation — pure filter, zero side effects

## Workflow

Read `skills/references/orchestrator-launch.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/orchestrator-launch.md`; if the Read fails, resolve it via `${CLAUDE_SKILL_DIR}/../references/orchestrator-launch.md`) and follow the launch protocol with these skill-specific policies:

1. **Step A** (agent names + script path): as written.
2. **Discover issues**:

   ```bash
   gh issue list --label <label> --state open --json number,title --jq '.[] | "\(.number)\t\(.title)"'
   ```

   If no issues are found, report to the user and exit.
3. **Step B** (lock filter): remove locked issues from the candidate list before triage; report skipped issues.
4. **Triage**: read `skills/references/triage.md` from the same directory and follow the triage protocol for each discovered issue.
5. **Confirm with user**: skip if `--yes`/`-y`. Otherwise present the triaged issue list and wait for confirmation; if the user declines, exit without action.
6. **Step C** (concurrency guard) — over-limit policy: **stop dispatching** (do NOT launch; remaining issues are left for the next run), notify via desktop notification, report which issues were dispatched and which deferred, then exit:

   ```bash
   source "${CEKERNEL_SCRIPTS}/shared/desktop-notify.sh"
   desktop_notify "cekernel: dispatch stopped" "Orchestrator limit reached (${CURRENT_ORCH}/${MAX_ORCH}). Remaining issues deferred."
   ```

7. **Step D** (session init): as written.
8. **Step E** (prompt + launch): as written.
