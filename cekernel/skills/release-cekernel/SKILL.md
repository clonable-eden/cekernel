---
description: Analyze git log, recommend a version bump, and trigger the plugin release workflow
argument-hint: "[version]"
allowed-tools: Bash, Read
---

# /release-cekernel

Analyzes the git log since the last release tag, recommends a semantic version bump level, and triggers the `plugin-release.yml` workflow to create a release PR.

## Usage

```
/release-cekernel
/release-cekernel 1.3.0
```

If a version is provided, skip the analysis and use it directly. Otherwise, analyze commits and recommend a version.

## Workflow

### Step 1: Determine Current Version and Last Tag

```bash
PREV_TAG=$(git tag -l 'cekernel-v*' --sort=-v:refname | head -1)
CURRENT_VERSION=$(jq -r '.version' cekernel/.claude-plugin/plugin.json)
echo "Current version: ${CURRENT_VERSION}"
echo "Last tag: ${PREV_TAG}"
```

### Step 2: Analyze Commits Since Last Tag

```bash
git log "${PREV_TAG}..HEAD" --oneline --no-merges
```

Classify each commit by its conventional commit prefix:

| Prefix | Category | Bump |
|--------|----------|------|
| `feat:` | New Features | minor |
| `fix:` | Bug Fixes | patch |
| `docs:` | Documentation | patch |
| `test:` | Tests | patch |
| `refactor:` | Refactoring | patch |
| Breaking changes | Breaking | major |

The highest-level bump wins:
- Any breaking change → **major**
- Any `feat:` → **minor**
- Otherwise → **patch**

### Step 3: Recommend Version

Calculate the recommended version from the current version and the determined bump level. Present to the user:

```
## Release Analysis

Last tag: cekernel-v1.2.0
Commits since last tag: N

### Changes
- feat: 2 commits (minor bump)
- fix: 3 commits
- docs: 1 commit

### Recommended bump: minor
### Proposed version: 1.3.0

Proceed? (y/n)
```

If the user provided a version argument, show the analysis but use the specified version instead.

Wait for user confirmation before proceeding.

### Step 4: Trigger Release Workflow

```bash
gh workflow run plugin-release.yml -f version=<VERSION> -f plugin=cekernel
```

### Step 5: Monitor Workflow

```bash
# Wait a few seconds for the run to appear
sleep 5
RUN_ID=$(gh run list --workflow=plugin-release.yml --limit=1 --json databaseId --jq '.[0].databaseId')
echo "Workflow run: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/${RUN_ID}"
gh run watch "${RUN_ID}"
```

### Step 6: Report Result

After the workflow completes, find the created PR:

```bash
PR_NUMBER=$(gh pr list --head "release/cekernel-v<VERSION>" --json number --jq '.[0].number')
echo "Release PR: #${PR_NUMBER}"
```

Report to the user:

```
## Release PR Created

- **PR**: #<number>
- **Branch**: release/cekernel-v<VERSION>
- **Version**: <VERSION>

### Next Steps
1. Review the PR and merge it
2. On merge, `plugin-release-tag.yml` will automatically create tag `cekernel-v<VERSION>` and GitHub Release
3. Edit the release notes to add categorized summary (see format below)
```

### Step 7: Release Notes Format

After the GitHub Release is auto-created, the release notes should follow this format. Instruct the user to edit the release at `https://github.com/<repo>/releases/tag/cekernel-v<VERSION>`:

```markdown
## Highlights
- Key changes in bullet points

## New Features
- feat: commit descriptions

## Bug Fixes
- fix: commit descriptions

## Documentation
- docs: commit descriptions

## What's Changed
* Auto-generated PR list (kept from --generate-notes)

**Full Changelog**: compare URL (kept from --generate-notes)
```

Generate a draft of the Highlights, New Features, Bug Fixes, and Documentation sections from the commit analysis in Step 2, and present it to the user for copy-paste into the release notes.
