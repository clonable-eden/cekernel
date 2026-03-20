# Issue Triage Protocol

> Canonical source for cekernel issue triage logic.
> Referenced by both `/orchestrate` and `/dispatch` skills.

## Pre-check: Lock Filter

Before triaging, skip any issue that is already locked by an active Worker. The calling skill is responsible for running `issue_lock_check` (from `scripts/shared/issue-lock.sh`) before entering triage — see dispatch/orchestrate SKILL.md for the concrete implementation.

## Single Issue Triage

For each issue, fetch its content **including comments** and verify:

```bash
gh issue view <N> --json number,title,body,labels,comments
```

Comments often contain critical information added after the initial issue description — such as investigation results, scope changes, clarifications, or updated requirements. Triage must consider the full conversation, not just the body.

1. **Clarity of requirements**: Are the required changes specifically described? Check both the body and comments for clarifications or scope adjustments.
2. **Scope**: Can the implementation scope be identified? Comments may narrow or expand the original scope.

If any issue has ambiguous or insufficient requirements, report to the user and confirm action (fix the issue, skip, proceed, etc.). If requirements become clear through user interaction, add supplementary information as a comment on the issue via `gh issue comment` so the Worker can work accurately.

## Multi-Issue Triage

When triaging multiple issues, additionally:

3. **Dependency analysis**: Analyze dependencies between issues (does completing A require B to finish first?)
4. **Phase ordering**: If dependencies exist, organize into phases and present the execution order to the user for confirmation

## Usage from SKILL.md

Each SKILL.md that needs triage should include a step like:

> Read `triage.md` (this file) and follow the triage protocol for each issue.

### Path Resolution

This file is located at `skills/references/triage.md` relative to the repository root. To find it:

1. Run `git rev-parse --show-toplevel` to get the repo root
2. Read `${REPO_ROOT}/skills/references/triage.md`
