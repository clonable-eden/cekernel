---
description: Release a new version of the cekernel plugin
allowed-tools: Read, Bash(git *), Bash(gh *)
---

# /release-cekernel

Release skill for the cekernel plugin. Analyzes git log to recommend a semver bump level, then triggers CI after user confirmation.

## Workflow

### Step 1: Get Current Version

Read the current version from `cekernel/.claude-plugin/plugin.json`.

### Step 2: Identify Latest Release Tag

```bash
git tag -l 'cekernel-v*' --sort=-v:refname | head -1
```

If no tag exists, consider the full history.

### Step 3: Get Changelog

```bash
# If a tag exists
git log <last-tag>..HEAD --oneline -- cekernel/

# If no tag exists
git log --oneline -- cekernel/
```

### Step 4: Determine Bump Level

Analyze changes according to semantic versioning rules to determine the bump level:

| Bump | Condition | Example |
|------|-----------|---------|
| **patch** | Bug fixes, documentation updates, test additions | `fix:`, `docs:`, `test:`, `refactor:` |
| **minor** | New scripts/skills, backward-compatible feature additions | `feat:` |
| **major** | Breaking changes: argument changes, deprecated env vars, removed scripts | Changes that break existing callers |

Use conventional commit prefixes as guidance while also considering the actual content of each commit.
When multiple changes are present, adopt the highest bump level.

### Step 5: Confirm with User

Present the following information to the user:

- Current version
- Changelog (list of commits)
- Recommended bump level and rationale
- New version

Proceed only after user confirmation. If the user specifies a different bump level, follow their choice.

### Step 6: Trigger CI

```bash
gh workflow run plugin-release.yml -f version=<new-version> -f plugin=cekernel
```

### Step 7: Verify Results

Check the workflow execution status and report the results to the user:

```bash
gh run list --workflow=plugin-release.yml --limit=1
```
