# Post-Mortem Detection Patterns

> Canonical checklist for `/postmortem` skill analysis.
> Each pattern describes a problem category, detection heuristic, and severity.
> Derived from analysis of issues [#335], [#340], [#347], [#349], [#358],
> [#372], [#373], [#374] transcripts and [ADR-0013] design patterns.
>
> [#335]: https://github.com/clonable-eden/cekernel/issues/335
> [#339]: https://github.com/clonable-eden/cekernel/issues/339
> [#340]: https://github.com/clonable-eden/cekernel/issues/340
> [#347]: https://github.com/clonable-eden/cekernel/issues/347
> [#349]: https://github.com/clonable-eden/cekernel/issues/349
> [#358]: https://github.com/clonable-eden/cekernel/issues/358
> [#372]: https://github.com/clonable-eden/cekernel/issues/372
> [#373]: https://github.com/clonable-eden/cekernel/issues/373
> [#374]: https://github.com/clonable-eden/cekernel/issues/374
> [ADR-0013]: ../../docs/adr/0013-transcript-based-postmortem-analysis.md

## How to Use

The `/postmortem` skill reads this file and instructs analysis subagents to check
each transcript against these patterns. When a match is found, the subagent reports
the category, evidence (transcript location), and severity.

Patterns are organized by category. Each has:
- **Detect**: What to look for in the transcript
- **Severity**: critical / warning / info
- **Class**: Root-cause classification (see below)
- **Example**: A real occurrence from past analysis

### Classification

| Class | Root Cause | Recommended Action |
|-------|-----------|-------------------|
| 1 | cekernel defect / configuration issue | Create issue in cekernel repository (user choice) |
| 2 | Project CLAUDE.md / rule gap | Create issue in target repository (recommended) |
| 3 | External constraint (GitHub API, Anthropic API, etc.) | Investigate whether known constraint |
| 4 | Claude Code defect | Investigate whether known constraint |

---

## IPC / State Anomalies

### IPC directory missing or deleted
- **Detect**: `no such file or directory` errors on `$CEKERNEL_IPC_DIR` paths, `worker_state_write` failures, FIFO-related errors
- **Severity**: critical
- **Class**: 1
- **Example**: [#335] — `worker_state_write` failed because IPC directory did not exist; Worker had to `mkdir -p` manually

### Stale lock files
- **Detect**: `issue_lock_check` returns locked for an issue with no active Worker process
- **Severity**: warning
- **Class**: 1

### FIFO corruption or missing
- **Detect**: `cat` or `echo` on FIFO paths returning errors, `mkfifo` failures
- **Severity**: critical
- **Class**: 1

---

## Agent Identity / Mismatch

### GitHub self-review constraint
- **Detect**: `gh pr review` returning `"Can not approve your own pull request"` or `"Can not request changes on your own pull request"`
- **Severity**: warning (systemic — known limitation when Worker and Reviewer share a GitHub identity)
- **Class**: 3
- **Example**: All 5 analyzed issues. Reviewer falls back to `--comment`, losing formal GitHub review status
- **Note**: This is an infrastructure constraint, not a bug. Track frequency but do not create issues unless the fallback also fails.

### Reviewer self-review fallback missing
- **Detect**: `gh pr review --approve` or `gh pr review --request-changes` failing with self-review error, followed by `notify-complete.sh failed` without a `--comment` fallback attempt; OR duplicate COMMENTED reviews (same body posted twice within seconds) caused by `gh pr review` CLI posting body even on failure
- **Severity**: warning
- **Class**: 1
- **Example**: #428 — Reviewer exited with `failed` without posting the review body; #430 — `gh pr review --approve` posted body as COMMENTED on failure, then `--comment` fallback posted it again (duplicate). Fix: use `gh api` with `event=APPROVE` which returns 422 without posting on self-review error

### Agent definition mismatch
- **Detect**: Reviewer transcript showing Worker-like behavior (implementation, commits), or Worker showing review-only behavior
- **Severity**: critical
- **Class**: 1
- **Example**: [#340] — Reviewer launched with Worker agent definition due to hardcoded env var

---

## CI / Test Issues

### Pre-existing test failures masking new failures
- **Detect**: Test suite exit code 1 where the failing test(s) also fail on main branch; Worker spending tool calls on `git stash` / checkout-main to verify pre-existing
- **Severity**: warning
- **Class**: 1
- **Example**: All 5 issues — `test-orchctrl-gc.sh` (bash 3.x `declare -A`) caused diagnostic overhead in every Worker session

### Excessive CI retries
- **Detect**: Same CI check failing 3+ times with the same error; `gh pr checks --watch` called repeatedly
- **Severity**: warning
- **Class**: 1

### Cross-platform compatibility failures
- **Detect**: Tests passing locally (macOS) but failing in CI (Linux), or vice versa. Common culprits: `sed -i` syntax, `xargs` empty-input behavior, `declare -A` bash version, `find` flag differences
- **Severity**: critical
- **Class**: 1
- **Example**: [#358] — `xargs -0 ls` behaves differently on GNU vs BSD (GNU runs command even with empty input); [#340] — `sed -i ''` macOS syntax

### Test update ripple effects missed
- **Detect**: Test failures caused by the Worker's own changes but in test files the Worker didn't modify; typically caught only by full test suite run
- **Severity**: warning
- **Class**: 1
- **Example**: [#347] — `test-backend-tmux.sh` and `test-backend-wezterm.sh` still asserted old `script -q` behavior after `script-capture.sh` removal; [#335] — `test-backend-dispatch.sh` expected `wezterm` default after it was changed to `headless`

---

## Protocol Deviations

### Missing checkpoint file
- **Detect**: Resumed Worker attempting to read `.cekernel-checkpoint.md` and getting file-not-found; Worker reconstructing context from GitHub API calls instead
- **Severity**: warning
- **Class**: 1
- **Example**: [#340], [#335] — Neither initial Worker session wrote a checkpoint, forcing resumed Workers to reconstruct context from PR comments and git log

### Reviewer not following linked documents
- **Detect**: Reviewer reading CLAUDE.md but not following `Read` instructions for linked documents (unix-philosophy.md, tdd.md, etc.)
- **Severity**: info
- **Class**: 2
- **Example**: [#347] — Reviewer read CLAUDE.md but did not read linked documents

### Direct push to main branch
- **Detect**: `git push origin main` or `git push origin master` in transcript, `Bypassed rule violations` in push output, `git commit` while on main/master branch without creating a feature branch
- **Severity**: warning
- **Class**: 2
- **Example**: [#372], [#373], [#374] — Orchestrator session committed and pushed SKILL.md changes directly to main, bypassing branch protection rules

### Worker skipping plan confirmation
- **Detect**: Worker posting execution plan as issue comment but immediately proceeding to implementation without waiting
- **Severity**: info (expected for automated Workers; CLAUDE.md instruction targets interactive sessions)
- **Class**: 2

---

## Script UX Issues

### Wrong script path
- **Detect**: `command not found` (exit 127) or `no such file or directory` for cekernel scripts; Worker using `find` to locate the correct path
- **Severity**: warning
- **Class**: 1
- **Example**: [#349] — Worker called `scripts/shared/notify-complete.sh` but actual path is `scripts/process/notify-complete.sh`

### PATH vs source confusion
- **Detect**: Worker trying to call a `source`-only function as a command (exit 127), or `source` with wrong path for shared helpers
- **Severity**: warning
- **Class**: 1
- **Example**: [#340] — Worker tried `task_file_clear_resume_marker` as a command; needed `source scripts/shared/task-file.sh` first

### Interactive prompt trap
- **Detect**: `rm` command hanging (run_in_background with no output), Worker using `TaskStop` to kill stuck command
- **Severity**: warning
- **Class**: 1
- **Example**: [#347] — `rm scripts/shared/script-capture.sh` triggered macOS confirmation prompt; should have used `git rm`

### Permission allowlist gaps
- **Detect**: Bash commands repeatedly rejected by sandbox with "requires approval"; agent trying 3+ variations of the same command
- **Severity**: critical
- **Class**: 1
- **Example**: [#335] — Reviewer attempted `gh pr review --approve` 22 times with different approaches, all blocked by permission model

---

## Worktree / Lifecycle Issues

### Worktree deleted while agent still active
- **Detect**: `Working directory no longer exists` errors; all subsequent Bash calls failing
- **Severity**: critical
- **Class**: 1
- **Example**: [#335] — Orchestrator deleted worktree while Reviewer was still attempting commands, permanently breaking the Reviewer session

---

## Test Isolation

### Production environment side effects
- **Detect**: Operations on `$CEKERNEL_IPC_DIR` or `$CEKERNEL_VAR_DIR` that are NOT within a test temp directory; `rm -rf` on non-temp paths
- **Severity**: critical
- **Class**: 1
- **Example**: [#339] — `run-tests.sh` inherited production `CEKERNEL_VAR_DIR` and deleted it at cleanup

### Worker operating on main repo instead of worktree
- **Detect**: `cd /path/to/main/repo` (not worktree path) followed by `git stash`, file modifications, or test execution
- **Severity**: warning
- **Class**: 1
- **Example**: [#340], [#349] — Workers used `git stash` on main repo for pre-existing failure diagnosis; harmless but risky pattern

---

## Tool Usage Anti-patterns

### Edit without Read
- **Detect**: Edit tool error `"File has not been read yet"` followed by Read + retry
- **Severity**: info
- **Class**: 4
- **Example**: [#335], [#340] — Worker attempted to edit files without reading them first

### Edit ambiguous match
- **Detect**: Edit tool error about non-unique `old_string`; Worker retrying with more context
- **Severity**: info
- **Class**: 4
- **Example**: [#340] — `replace_all: false` but the target string appeared multiple times

### Worker losing track of own state
- **Detect**: 3+ consecutive `git status`/`git diff`/`git log` commands without intervening edits or commits; Worker checking whether changes are committed when they already are
- **Severity**: info
- **Class**: 4
- **Example**: [#335] — Worker ran 6 consecutive git inspection commands before realizing changes were already committed
