# Issue Triage Protocol

> Canonical source for cekernel issue triage logic.
> Referenced by both `/orchestrate` and `/dispatch` skills.

## Single Issue Triage

For each issue, check its content with `gh issue view` and verify:

1. **Clarity of requirements**: Are the required changes specifically described?
2. **Scope**: Can the implementation scope be identified?

If any issue has ambiguous or insufficient requirements, report to the user and confirm action (fix the issue, skip, proceed, etc.). If requirements become clear through user interaction, add supplementary information as a comment on the issue via `gh issue comment` so the Worker can work accurately.

## Multi-Issue Triage

When triaging multiple issues, additionally:

3. **Dependency analysis**: Analyze dependencies between issues (does completing A require B to finish first?)
4. **Phase ordering**: If dependencies exist, organize into phases and present the execution order to the user for confirmation

## Usage from SKILL.md

Each SKILL.md that needs triage should include a step like:

> Read `triage.md` (this file) and follow the triage protocol for each issue.

### Path Resolution

This file is located at `cekernel/skills/references/triage.md` relative to the repository root. To find it:

1. Run `git rev-parse --show-toplevel` to get the repo root
2. Read `${REPO_ROOT}/cekernel/skills/references/triage.md`
