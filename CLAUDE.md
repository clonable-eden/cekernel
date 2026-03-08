# cekernel Development Guide

cekernel is a parallel agent infrastructure for Claude Code.
It maps Unix concepts (processes, IPC, schedulers) onto Claude workflows.
See [README.md](./README.md) for architecture details.

## Principles

- When uncertain about Claude Code specifications or behavior, always consult primary sources (official documentation, GitHub issues) before answering. Do not guess.
- Links in CLAUDE.md are not references — they are part of the instructions. You MUST read linked documents and follow them.

## Philosophy

cekernel's design is rooted in UNIX philosophy and TDD.

- [UNIX Philosophy](./docs/unix-philosophy.md) — Eric S. Raymond's 17 principles
- [TDD](./docs/tdd.md) — Red-Green-Refactor cycle and testing principles

## Scripts

### Basic Rules

All scripts must begin with:

```bash
set -euo pipefail
```

Source `shared/session-id.sh` to establish session scope:

```bash
source "${SCRIPT_DIR}/../shared/session-id.sh"
```

### Shared Helpers

Each helper in `scripts/shared/` has a header comment documenting its API (functions, arguments, return values). Read the script file directly for usage details.

### Known Pitfalls

`((var++))` returns exit 1 when `var=0` (bash treats 0 as falsy in arithmetic expressions).
Under `set -e` this causes immediate termination. Use `var=$((var + 1))` instead:

```bash
# BAD: terminates under set -e when FAILED=0
((FAILED++))

# OK
FAILED=$((FAILED + 1))
```

### Environment Variables

Use the `CEKERNEL_` prefix. Use `${VAR:-default}` pattern for default values. See [`envs/README.md`](./envs/README.md) for the full variable catalog.

Use `BASH_SOURCE[0]`-based path resolution for locating files relative to the script:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

### Flag Parsing

Use a `while-case` loop (see `cleanup-worktree.sh --force`):

```bash
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    *) break ;;
  esac
done
```

### Positional Argument Validation

Use the `${1:?Usage: ...}` pattern:

```bash
ISSUE_NUMBER="${1:?Usage: spawn-worker.sh <issue-number> [base-branch]}"
BASE_BRANCH="${2:-main}"
```

## Agents & Skills

### Frontmatter

Agents and skills use different frontmatter key names for tool access:

| Type | File | Key | Example |
|------|------|-----|---------|
| Agent | [`agents/*.md`](./agents/) | `tools` | `tools: Read, Edit, Write, Bash` |
| Skill | [`skills/*/SKILL.md`](./skills/) | `allowed-tools` | `allowed-tools: Read, Bash, Task` |

Agent frontmatter:

```yaml
name: <agent-name>
description: <description>
tools: Read, Edit, Write, Bash
```

### Skill References

Shared logic used by multiple skills is placed in `skills/references/` as markdown files. Skills read these via the `Read` tool and execute the instructions.

```
skills/references/
├── namespace-detection.md   # Plugin vs local detection (ADR-0009)
└── triage.md                # Issue triage protocol
```

This avoids duplicating the same logic across multiple SKILL.md files. When the shared logic changes, only the reference file needs updating.

## ADRs

Architecture Decision Records are stored in [`docs/adr/`](./docs/adr/). Use `/unix-architect adr <topic>` to create new ADRs.

Numbering: check the latest file with `ls docs/adr/*.md | sort -V | tail -1` and increment.

Status lifecycle: `Proposed` → `Accepted` (or `Rejected`). Amendments are added as subsections within the original ADR.

## Testing

### What to Test

Test only the **behavior of executable scripts**.

- OK: `session-id.sh` generates and exports `SESSION_ID`
- OK: `spawn-worker.sh` returns exit 2 when the concurrency limit is exceeded
- NG: Grep-testing `*.md` content to verify specific strings are present

### Test File Naming

```
tests/
├── run-tests.sh             # Test runner
├── helpers.sh               # Assertion functions
├── orchestrator/
│   ├── test-concurrency-guard.sh
│   └── test-{feature}.sh   # Orchestrator script tests
├── worker/
│   └── test-{feature}.sh   # Worker script tests
├── shared/
│   ├── test-session-id.sh   # session-id.sh tests
│   └── test-{feature}.sh   # Shared helper tests
└── scheduler/
    └── test-{feature}.sh   # Scheduler script tests
```

### Assertion Functions

Use the functions provided by `helpers.sh`:

```bash
assert_eq <label> <expected> <actual>
assert_match <label> <regex-pattern> <actual>
assert_file_exists <label> <path>
assert_fifo_exists <label> <path>
assert_dir_exists <label> <path>
assert_not_exists <label> <path>
report_results  # "Results: N passed, M failed"
```

### Test Isolation

Isolate commands with side effects (WezTerm, `gh`, `git worktree`) from tests, or structure them to be mockable.

Use a dedicated `CEKERNEL_SESSION_ID` in tests, and clean up before and after:

```bash
export CEKERNEL_SESSION_ID="test-feature-00000001"
source "${CEKERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$CEKERNEL_IPC_DIR"
mkdir -p "$CEKERNEL_IPC_DIR"
# ... tests ...
rm -rf "$CEKERNEL_IPC_DIR"
```

## CI

GitHub Actions runs `run-tests.sh` when changes are detected. PRs that fail tests are not merged.

## Versioning

`/plugin update` uses the version string in `plugin.json` to determine differences.
Version management is automated via the `/release-cekernel` skill and GitHub Actions.

### Semantic Versioning Rules

| Bump | Condition | Example |
|------|-----------|---------|
| **patch** | Bug fixes, documentation updates, test additions | `fix:`, `docs:`, `test:`, `refactor:` |
| **minor** | New scripts/skills, backward-compatible feature additions | `feat:` |
| **major** | Breaking changes: argument changes, deprecated env vars, removed scripts | Changes that break existing callers |

### Release Procedure

```bash
/release-cekernel
```

The skill analyzes git log and recommends a bump level. After confirmation:

1. CI creates a `release/cekernel-vX.Y.Z` branch with the version bump and opens a PR
2. Human reviews and merges the PR (follows normal branch protection)
3. `plugin-release-tag.yml` automatically creates the tag and GitHub Release on merge
4. Human edits the release notes to add categorized summary

### Versioned Artifacts

- `.claude-plugin/plugin.json` — Plugin manifest

### Tag Format

`cekernel-v{major}.{minor}.{patch}` (prefixed for future multi-plugin support)

## Conventions

- Branch names: `issue/{number}-{short-description}`
- Commit message titles in English, body preferably in English
- PR body must include `closes #{issue-number}`
- GitHub issues, issue comments, and PR descriptions are written in Japanese by default
- RELEASE_NOTES.md is written in English (What's Changed section uses PR titles as-is)
- Never commit directly to main. Always create a feature branch and open a PR
- Use regular merge (not squash) for PRs unless explicitly told otherwise
- Worktrees are created under `.worktrees/` (already in .gitignore)
- Commit messages follow conventional commits:
  - `feat:` New feature
  - `fix:` Bug fix
  - `docs:` Documentation only
  - `test:` Tests only
  - `refactor:` Refactoring
  - `release:` Version bump (CI auto-generated)

## Issue Management

- Issues labeled `idea` or exploratory topics should follow: ADR first → then implementation issue(s)
- Large or complex issues should be broken down into smaller sub-issues that a Worker can complete independently
- Each issue should be scoped so that a single Worker can implement, test, and merge it without ambiguity

## Safety

- Never delete the current working directory (CWD) or its parent during a session. If cleanup is needed, `cd` to a safe directory first
- When the user has a problem visible in terminal output, proactively diagnose it rather than asking what the problem is

## Self-hosting

cekernel's own issues are also resolved using `/orchestrate`.
This CLAUDE.md also serves as a guide for Workers developing cekernel itself.
