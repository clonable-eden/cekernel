# cekernel

Parallel agent infrastructure for Claude Code. Modeled after the OS process model,
it distributes, monitors, and reaps issues via independent Workers.

## Concept

```
Orchestrator (agent1)              Worker (agent2, 3, 4, ...)
  main working tree                  git worktree per issue
  ┌─────────────┐                  ┌─────────────┐
  │ receive issue│                  │ implement    │
  │ create wktree│──spawn──────→   │ test         │
  │ monitor FIFO │                  │ create PR    │
  │   ...waiting │                  │ CI + merge   │
  │   ←─signal───│◄─notify─────── │ notify done  │
  │ cleanup      │                  └─────────────┘
  └─────────────┘
```

### OS Analogy

| OS | kernel |
|----|--------|
| `init` / scheduler | Orchestrator |
| process | Worker |
| `fork` + `exec` | `spawn-worker.sh` |
| address space | git worktree |
| IPC pipe | named pipe (FIFO) |
| IPC namespace | session (`CEKERNEL_SESSION_ID`) |
| `waitpid` | `watch-worker.sh` |
| zombie reaping | `cleanup-worktree.sh` |
| PID | issue number |
| `/var/log/` | `${CEKERNEL_IPC_DIR}/logs/` |
| `syslog` | Lifecycle event log writes |
| `tail -f` / `journalctl` | `watch-logs.sh` |
| log rotation | Logs deleted by `cleanup-worktree.sh` |
| page cache | `.cekernel-task.md` (issue data pre-extracted at spawn) |
| `ulimit -u` (max processes) | `CEKERNEL_MAX_WORKERS` |
| `ps aux` | `worker-status.sh` |
| process scheduler | Orchestrator queuing logic |
| semaphore | Concurrency guard via FIFO count |

## Structure

```
cekernel/
  .claude-plugin/
    plugin.json              # Plugin manifest
  Makefile                   # WezTerm plugin install/uninstall
  agents/
    orchestrator.md          # Orchestrator protocol definition
    worker.md                # Worker protocol definition
  config/
    wezterm.cekernel.lua     # WezTerm plugin (Worker layout via user-var event)
  skills/
    orchestrate/
      SKILL.md               # /cekernel:orchestrate skill
  envs/
    README.md                # Environment variable catalog
    default.env              # Default profile (wezterm, 3 workers)
    headless.env             # Headless profile (headless, 5 workers)
    ci.env                   # CI profile (headless, 1800s timeout)
  scripts/
    orchestrator/
      spawn-worker.sh        # Create worktree + launch Worker via backend (with concurrency guard)
      watch-worker.sh        # Monitor Worker completion via FIFO
      watch-logs.sh          # Real-time Worker log monitoring
      cleanup-worktree.sh    # Remove worktree + branch + logs
      health-check.sh        # Detect zombie Workers
      worker-status.sh       # List active Workers
    worker/
      notify-complete.sh     # Worker → Orchestrator completion notification
    shared/
      session-id.sh          # Session ID generation + IPC directory derivation
      claude-json-helper.sh  # ~/.claude.json trust entry read/write helper
      backend-adapter.sh     # Backend abstraction layer (wezterm/tmux/headless)
      task-file.sh           # Local task file extraction (session memory: page cache)
      load-env.sh            # Environment profile loader (multi-layer search)
  tests/
    run-tests.sh             # Test runner
    helpers.sh               # Assertion helpers
    orchestrator/test-*.sh   # Orchestrator script tests
    worker/test-*.sh         # Worker script tests
    shared/test-*.sh         # Shared helper tests
```

## Dependencies

| Tool | Purpose | Required |
|------|---------|----------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Runtime for Worker agents | Yes |
| [jq](https://jqlang.github.io/jq/) | `~/.claude.json` trust entry manipulation, JSON parsing | Yes |
| [gh](https://cli.github.com/) | Issue retrieval, PR creation/merge | Yes |
| [WezTerm](https://wezfurlong.org/wezterm/) | Worker window launch/management (wezterm backend) | No* |
| [tmux](https://github.com/tmux/tmux) | Worker pane management (tmux backend) | No* |
| git | Worktree creation/management | Yes |

\* One backend is required: WezTerm (default), tmux, or headless. Set `CEKERNEL_BACKEND` env var to select. Headless requires no terminal.

## Install

Install from the Claude Code plugin marketplace:

```bash
# 1. Add marketplace
/plugin marketplace add clonable-eden/glimmer

# 2. Install cekernel plugin
/plugin install cekernel@clonable-eden-glimmer
```

### WezTerm Plugin

If using the WezTerm backend, install the WezTerm plugin into `plugins.d/` (recommended):

```bash
cd cekernel
make install    # Symlinks config/wezterm.cekernel.lua → ~/.config/wezterm/plugins.d/cekernel.lua
make uninstall  # Removes the symlink

# or
make -C cekernel install # uninstall
```

This requires a `plugins.d` loader in your `wezterm.lua` (before `return config`):

```lua
-- ============================================================
-- Plugins: load all .lua files from plugins.d/
-- ============================================================
for _, file in ipairs(wezterm.glob(wezterm.config_dir .. '/plugins.d/*.lua')) do
  dofile(file)
end
```

If you manage your own WezTerm config, you can load `config/wezterm.cekernel.lua` directly instead.

### Update

```bash
# 1. Update marketplace repository
/plugin marketplace update

# 2. Update plugin
/plugin update

# 3. Restart Claude Code to apply
```

> **Note**: `/plugin update` alone may not update the marketplace local clone.
> Always run `/plugin marketplace update` first.

## Configuration

cekernel is configured via `CEKERNEL_*` environment variables. See [`envs/README.md`](./envs/README.md) for the full catalog.

Named profiles (`.env` files) provide coherent sets of defaults for common scenarios:

| Profile | Use case |
|---------|----------|
| `default.env` | Local development with WezTerm |
| `headless.env` | Terminal-free execution (CI, cron) |
| `ci.env` | CI-specific settings |

Select a profile via `CEKERNEL_ENV`:

```bash
export CEKERNEL_ENV=headless   # default: "default"
```

Profiles are loaded with multi-layer priority (lowest → highest):

1. Script defaults (`${VAR:-default}`)
2. Plugin profile (`${CLAUDE_PLUGIN_ROOT}/envs/${CEKERNEL_ENV}.env`)
3. Project override (`.cekernel/envs/${CEKERNEL_ENV}.env`)
4. Explicit environment variables

Projects can override plugin defaults by placing `.env` files in `.cekernel/envs/`. These survive `/plugin update`. See ADR-0006 for design details.

## Usage

```bash
# Run Orchestrator workflow via skill
/cekernel:orchestrate

# Or execute scripts directly (same steps as Orchestrator)

# 1. Generate CEKERNEL_SESSION_ID
source cekernel/scripts/shared/session-id.sh && echo $CEKERNEL_SESSION_ID
# => glimmer-7861a821

# 2. Execute scripts (all require CEKERNEL_SESSION_ID; export each time if shells are separate)
export CEKERNEL_SESSION_ID=glimmer-7861a821 && cekernel/scripts/orchestrator/spawn-worker.sh 4
export CEKERNEL_SESSION_ID=glimmer-7861a821 && cekernel/scripts/orchestrator/worker-status.sh
export CEKERNEL_SESSION_ID=glimmer-7861a821 && cekernel/scripts/orchestrator/watch-worker.sh 4  # run_in_background: true
export CEKERNEL_SESSION_ID=glimmer-7861a821 && cekernel/scripts/orchestrator/watch-logs.sh
export CEKERNEL_SESSION_ID=glimmer-7861a821 && cekernel/scripts/orchestrator/watch-logs.sh 4
export CEKERNEL_SESSION_ID=glimmer-7861a821 && cekernel/scripts/orchestrator/cleanup-worktree.sh 4

# Change concurrency limit (default: 3)
export CEKERNEL_MAX_WORKERS=5
```

For versioning and release procedures, see the [cekernel/CLAUDE.md Versioning section](./CLAUDE.md#versioning).

## Worker Permissions

Worker / Orchestrator agent definitions have `tools` configured, granting access to:

| Tool | Purpose |
|------|---------|
| `Read` | File reading |
| `Edit` | File editing |
| `Write` | File writing |
| `Bash` | All Bash commands including git, gh, shell scripts |

`spawn-worker.sh` launches Workers with `claude --agent ${CEKERNEL_AGENT_WORKER}`.
The agent name is resolved dynamically: `cekernel:worker` in plugin mode, `worker` in local mode.
The `--agent` flag applies the agent definition's `tools`.

Tool auto-approval (without permission prompts) is delegated to the target repository's `.claude/settings.json`.
cekernel does not hardcode tool permissions.

Note that agents and skills use different frontmatter key names:
- **Agents** (`agents/*.md`): `tools`
- **Skills** (`skills/*/SKILL.md`): `allowed-tools`

## Project Configuration

Repositories using cekernel need to configure tool permissions in `.claude/settings.json`.
Workers automatically read this configuration file within the worktree and operate without permission prompts.

```json
{
  "permissions": {
    "allow": [
      "Bash",
      "Edit",
      "Write",
      "Read"
    ],
    "deny": [
      "Bash(sudo *)",
      "Bash(rm -rf /)",
      "Bash(rm -rf /*)"
    ]
  }
}
```

List tools that Workers should use in `allow`, and explicitly deny dangerous commands in `deny`.
Each repository can freely customize allowed tools and commands.

## TDD Workflow

Workers implement code-changing issues using TDD (Red-Green-Refactor).

```
RED ──→ GREEN ──→ REFACTOR ──→ (next cycle or Phase 2)
 │        │          │
 │        │          └─ Remove duplication, improve naming, restructure → commit
 │        └─ Minimal implementation to pass tests → commit
 └─ Write failing test → commit
```

Documentation-only changes and similar cases where tests are unnecessary may skip TDD.
See the "Development Method: TDD" section in `agents/worker.md` for details.

## Constraint: Separation of Authority

cekernel defines only the **lifecycle** (spawn → PR → CI → merge → notify → cleanup).

When Workers actually write code, they **fully follow the target repository's CLAUDE.md and project conventions**.
If cekernel rules conflict with the target repository's conventions, the target repository always takes precedence.

```
cekernel authority        Target repository authority
─────────────────         ──────────────────────────
When to create PR         How to implement
When to verify CI         Coding conventions
When to merge             Test policies / lint rules
When to notify            commit message format
                          PR template
                          Merge strategy
                          Branch naming conventions
                          Issue link syntax
```

If the target repository has no CLAUDE.md, Workers infer conventions from existing code, commits, and PRs.

## Logging

Worker lifecycle events are recorded in the session-scoped log directory.

```
/tmp/cekernel-ipc/{CEKERNEL_SESSION_ID}/
├── worker-4          # FIFO (existing)
├── worker-7          # FIFO (existing)
└── logs/
    ├── worker-4.log  # Worker #4 log
    └── worker-7.log  # Worker #7 log
```

### Log Format

```
[2026-02-25T15:30:00Z] SPAWN issue=#4 branch=issue/4-add-feature
[2026-02-25T15:45:00Z] COMPLETE issue=#4 status=merged detail=42
[2026-02-25T15:46:00Z] FAILED issue=#7 status=failed detail=CI failed 3 times
```

### Log Monitoring

```bash
cekernel/scripts/orchestrator/watch-logs.sh             # All Workers
cekernel/scripts/orchestrator/watch-logs.sh 4           # Specific Worker
```

### Log Lifecycle

- **Creation**: `spawn-worker.sh` creates on Worker spawn
- **Writing**: `spawn-worker.sh` (SPAWN), `notify-complete.sh` (COMPLETE/FAILED)
- **Deletion**: `cleanup-worktree.sh` deletes during worktree cleanup

## Resource Governance

### Concurrency Limit

The `CEKERNEL_MAX_WORKERS` environment variable limits concurrent Workers (default: 3).
`spawn-worker.sh` counts active FIFOs in the session and returns exit 2 when the limit is reached.
The Orchestrator uses this exit code to perform queuing.

### Worker Status

Use `worker-status.sh` to check active Workers in the session in JSON Lines format:

```bash
cekernel/scripts/orchestrator/worker-status.sh
# {"issue":4,"worktree":"/path/.worktrees/issue/4-...","fifo":"/tmp/cekernel-ipc/.../worker-4","uptime":"12m"}
```


## IPC: Named Pipe

Inter-Worker communication uses FIFOs (named pipes). No daemon required, kernel-level IPC, `select`/`poll` compatible.

### Session Scope

FIFO paths are namespaced per session:

```
/tmp/cekernel-ipc/{CEKERNEL_SESSION_ID}/worker-{issue}
```

`CEKERNEL_SESSION_ID` is auto-generated by `session-id.sh` (format: `{repo-name}-{hex8}`).
If the `CEKERNEL_SESSION_ID` environment variable is already set, it is used as-is.
spawn-worker.sh propagates `CEKERNEL_SESSION_ID` to Workers via the backend (WezTerm Lua event, tmux send-keys, or environment variable for headless).

This ensures that multiple orchestrate sessions running concurrently on the same machine do not have FIFO collisions.
