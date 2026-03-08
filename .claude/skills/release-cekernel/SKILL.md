---
description: Analyze git log, recommend a version bump, and create a release PR with structured release notes
argument-hint: "[version]"
allowed-tools: Bash, Read, Edit, Write
---

# /release-cekernel

Analyzes the git log since the last release tag, recommends a semantic version bump level, generates structured release notes, and creates a release PR directly.

## Usage

```
/release-cekernel
/release-cekernel 1.4.0
```

If a version is provided, skip the analysis and use it directly. Otherwise, analyze commits and recommend a version.

## Workflow

### Step 1: Determine Current Version and Last Tag

```bash
PREV_TAG=$(git tag -l 'cekernel-v*' --sort=-v:refname | head -1)
CURRENT_VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
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

Last tag: cekernel-v1.3.0
Commits since last tag: N

### Changes
- feat: 2 commits (minor bump)
- fix: 3 commits
- docs: 1 commit

### Recommended bump: minor
### Proposed version: 1.4.0

Proceed? (y/n)
```

If the user provided a version argument, show the analysis but use the specified version instead.

Wait for user confirmation before proceeding.

### Step 4: Generate Release Notes

Generate `RELEASE_NOTES.md` following the [cekernel-v1.2.0](https://github.com/clonable-eden/cekernel/releases/tag/cekernel-v1.2.0) format.

#### 4a: Gather PR list

```bash
# Get merged PRs between last tag and HEAD
git log "${PREV_TAG}..HEAD" --merges --oneline
```

Also use the GitHub API to get PR details:

```bash
gh pr list --state merged --base main --search "merged:>=$(git log -1 --format=%ci ${PREV_TAG} | cut -d' ' -f1)" --json number,title,author --limit 100
```

#### 4b: Build release notes

Generate the following sections from the commit and PR analysis:

```markdown
## Highlights
- Summary of the most important changes in this release (3-8 bullet points)
- Focus on user-facing impact, not implementation details
- Bold key terms for scannability

## New Features
- feat: commit descriptions (one bullet per feature)

## Bug Fixes
- fix: commit descriptions (one bullet per fix)

## Documentation
- docs: commit descriptions (one bullet per doc change)

## What's Changed
* PR title by @author in PR-URL (one line per merged PR)

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/${PREV_TAG}...cekernel-v${VERSION}
```

Rules:
- **Highlights** is written by Claude based on understanding of the changes. Summarize themes, not individual commits.
- **New Features / Bug Fixes / Documentation** are derived from conventional commit prefixes. `refactor:` and `test:` commits go under a **Other Changes** section if present.
- **What's Changed** lists all merged PRs with author attribution and links (same format as GitHub's `--generate-notes`).
- **Full Changelog** is the compare URL between the previous tag and the new tag.

#### 4c: Present for review

Show the generated release notes to the user and wait for confirmation. The user may request edits before proceeding.

### Step 5: Create Release Branch and PR

After the user confirms both the version and the release notes:

#### 5a: Create release branch

```bash
git checkout -b "release/cekernel-v${VERSION}"
```

#### 5b: Update plugin.json version

Use `jq` to update the version field:

```bash
jq --arg v "${VERSION}" '.version = $v' .claude-plugin/plugin.json > tmp.json
mv tmp.json .claude-plugin/plugin.json
```

#### 5c: Write RELEASE_NOTES.md

Write the confirmed release notes to `RELEASE_NOTES.md` at the repository root.

#### 5d: Commit and push

```bash
git add .claude-plugin/plugin.json RELEASE_NOTES.md
git commit -m "release: cekernel v${VERSION}"
git push -u origin "release/cekernel-v${VERSION}"
```

#### 5e: Create PR

```bash
gh pr create \
  --title "release: cekernel v${VERSION}" \
  --body "$(cat <<EOF
Version bump for cekernel plugin.

- Updates \`.claude-plugin/plugin.json\` version to \`${VERSION}\`
- Adds \`RELEASE_NOTES.md\` for structured release notes
- On merge, \`plugin-release-tag.yml\` will automatically create tag \`cekernel-v${VERSION}\` and GitHub Release

EOF
)"
```

### Step 6: Report Result

```
## Release PR Created

- **PR**: #<number>
- **Branch**: release/cekernel-v<VERSION>
- **Version**: <VERSION>

### Next Steps
1. Review the PR and merge it
2. On merge, `plugin-release-tag.yml` will automatically create tag `cekernel-v<VERSION>` and GitHub Release with the contents of RELEASE_NOTES.md
```
