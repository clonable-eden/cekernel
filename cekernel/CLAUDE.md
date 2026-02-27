# cekernel Development Guide

cekernel is a parallel agent infrastructure for Claude Code.
It maps Unix concepts (processes, IPC, schedulers) onto Claude workflows.
See [README.md](./README.md) for architecture details.

## Philosophy

cekernel's design is rooted in UNIX philosophy and TDD.

- [UNIX Philosophy](./docs/unix-philosophy.md) — Eric S. Raymond's 17 principles
- [TDD](./docs/tdd.md) — Red-Green-Refactor cycle and testing principles

## Architecture

```
cekernel/
├── agents/          # Agent definitions (orchestrator, worker)
├── scripts/
│   ├── orchestrator/  # Orchestrator scripts
│   ├── worker/        # Worker scripts
│   └── shared/        # Shared helpers (session-id, claude-json-helper, etc.)
├── skills/          # Skill definitions (/cekernel:orchestrate)
└── tests/
    ├── orchestrator/  # Orchestrator script tests
    ├── worker/        # Worker script tests
    └── shared/        # Shared helper tests
```

Key mappings:

| Unix | kernel |
|------|--------|
| scheduler | Orchestrator agent |
| process | Worker agent |
| `fork` + `exec` | `spawn-worker.sh` |
| address space | git worktree |
| IPC pipe | named pipe (FIFO) |
| IPC namespace | `CEKERNEL_SESSION_ID` |
| page cache | `.cekernel-task.md` |

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

### shared/task-file.sh

A helper for extracting issue data into a local `.cekernel-task.md` file in the worktree at spawn time. Workers read this file instead of calling `gh issue view`, reducing GitHub API calls and context window consumption (OS analogy: page cache).

```bash
source "${SCRIPT_DIR}/../shared/task-file.sh"
create_task_file "$WORKTREE" "$ISSUE_NUMBER"  # Fetch issue and write .cekernel-task.md
task_file_path "$WORKTREE"                    # Returns path to .cekernel-task.md
task_file_exists "$WORKTREE"                  # Returns 0 if file exists
```

### shared/claude-json-helper.sh

A helper for safely reading and writing trust entries in `~/.claude.json`. Shared by `spawn-worker.sh` and `cleanup-worktree.sh`.

```bash
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
register_trust "$WORKTREE"    # Register trust for the worktree path
unregister_trust "$WORKTREE"  # Unregister trust for the worktree path
```

Uses mkdir-based file locking (`acquire_claude_json_lock` / `release_claude_json_lock`) to prevent concurrent writes. In tests, override paths via the `CLAUDE_JSON` / `LOCK_DIR` environment variables.

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

Use the `CEKERNEL_` prefix.

Use `${VAR:-default}` pattern for default values:

```bash
MAX_WORKERS="${CEKERNEL_MAX_WORKERS:-3}"
TIMEOUT="${CEKERNEL_WORKER_TIMEOUT:-3600}"
```

`CLAUDE_PLUGIN_ROOT` is set automatically by Claude Code only when executed via a skill. Add a `SCRIPT_DIR`-based fallback for direct execution:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
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

## Agents

### Frontmatter

Agent definition files require the following frontmatter:

```yaml
name: <agent-name>
description: <description>
tools: Read, Edit, Write, Bash
```

### Separation of Authority

cekernel defines only the lifecycle (spawn → PR → merge → notify).
Implementation conventions follow the target repository's CLAUDE.md.

The Worker launch prompt includes instructions to "read the target repository's CLAUDE.md and fully follow its conventions."

Tool availability is defined by the agent frontmatter's `tools` key. Tool auto-approval (skipping permission prompts) is fully delegated to the target repository's `.claude/settings.json`. cekernel does not specify `--allowedTools` or `permissionMode`. Claude Code automatically reads `.claude/settings.json` within the worktree, enabling per-repository permission configuration. Skill files use `allowed-tools` (note the different key name between agents and skills).

### Worker Protocol

`worker.md` defines the following phases:

1. **Phase 0** — Read the target repository's CLAUDE.md → Post Execution Plan as a comment on the issue
2. **Phase 1** — Implementation (TDD for code changes: RED → GREEN → REFACTOR)
3. **Phase 2** — Create PR
4. **Phase 3** — CI verification + merge
5. **Phase 4** — Post Result as a comment on the issue → Completion notification via `notify-complete.sh`

TDD is always performed for issues involving code changes. Workers may skip TDD at their discretion for documentation-only changes and similar cases.

When TDD is applied, commit messages include a phase suffix: `(RED)`, `(GREEN)`, `(REFACTOR)`.

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
└── shared/
    ├── test-session-id.sh   # session-id.sh tests
    └── test-{feature}.sh   # Shared helper tests
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

GitHub Actions runs `run-tests.sh` when changes are detected in the `cekernel/**` path. PRs that fail tests are not merged.

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

The skill analyzes git log and recommends a bump level. After confirmation, it triggers CI via `gh workflow run`, and CI performs the version bump + commit + tag + push.

### Versioned Artifacts

- `cekernel/.claude-plugin/plugin.json` — Plugin manifest

### Tag Format

`cekernel-v{major}.{minor}.{patch}` (prefixed for future multi-plugin support)

## Conventions

Inherits from the root [CLAUDE.md](../CLAUDE.md):

- Branch names: `issue/{number}-{short-description}`
- Commit message titles in English, body preferably in English
- PR body must include `closes #{issue-number}`

## Self-hosting

cekernel's own issues are also resolved using `/cekernel:orchestrate`.
This CLAUDE.md also serves as a guide for Workers developing cekernel itself.
