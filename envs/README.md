# Environment Variable Catalog

All `CEKERNEL_*` environment variables used by cekernel.

## User-configurable Variables

These can be set via env profiles or explicit `export`.

| Variable | Default | Valid Values | Used by | Purpose |
|----------|---------|-------------|---------|---------|
| `CEKERNEL_BACKEND` | `wezterm` | `wezterm`, `tmux`, `headless` | `backend-adapter.sh` | Select Worker process backend |
| `CEKERNEL_MAX_PROCESSES` | `3` | Positive integer | `spawn.sh` | Maximum concurrent processes |
| `CEKERNEL_MAX_WORKERS` | — | Positive integer | `spawn.sh` | **Deprecated**: use `CEKERNEL_MAX_PROCESSES`. If set, overrides `CEKERNEL_MAX_PROCESSES` and emits a warning |
| `CEKERNEL_WORKER_TIMEOUT` | `3600` | Positive integer (seconds) | `watch.sh` | Worker timeout before auto-termination |
| `CEKERNEL_CHECKPOINT_FILENAME` | `.cekernel-checkpoint.md` | Any filename | `checkpoint-file.sh` | Checkpoint file name in worktree |
| `CEKERNEL_TASK_FILENAME` | `.cekernel-task.md` | Any filename | `task-file.sh` | Task file name in worktree |
| `CEKERNEL_CI_MAX_RETRIES` | `3` | Positive integer | `worker.md` (Phase 3) | Maximum CI retry attempts before Worker reports failure |
| `CEKERNEL_AUTO_MERGE` | `false` | `true`, `false` | Orchestrator | `true`: Reviewer 承認後に Orchestrator が自動マージ。`false`: desktop 通知のみ、人間がマージ |
| `CEKERNEL_REVIEW_MAX_RETRIES` | `2` | Positive integer | Orchestrator | Reviewer の reject → Worker re-implement サイクルの上限。超過時は人間にエスカレーション |
| `CEKERNEL_VAR_DIR` | `/usr/local/var/cekernel` | Directory path | `registry.sh`, `wrapper.sh` | Runtime state directory (locks, logs, runners, registry) |

## Internal Variables

Auto-generated or derived. Not intended for user configuration.

| Variable | Default | Used by | Purpose |
|----------|---------|---------|---------|
| `CEKERNEL_SESSION_ID` | Auto-generated (`{repo}-{hex8}`) | `session-id.sh` -> all scripts | Session namespace for IPC |
| `CEKERNEL_IPC_DIR` | `/usr/local/var/cekernel/ipc/${SESSION_ID}` | `session-id.sh` -> all scripts | IPC directory path |
| `CEKERNEL_ACTIVE_BACKEND` | Derived from `CEKERNEL_BACKEND` | `backend-adapter.sh` (internal) | Resolved backend name |

## Meta Variable

| Variable | Default | Used by | Purpose |
|----------|---------|---------|---------|
| `CEKERNEL_ENV` | `default` | `load-env.sh` | Select which env profile to load |

## Profiles

Env profiles are `.env` files containing coherent sets of variable assignments.
Profiles are **partial** — they only set variables that differ from defaults.

### Loading Priority (lowest to highest)

1. **Script defaults** — `${VAR:-default}` in each script
2. **Plugin profile** — `envs/${CEKERNEL_ENV}.env`
3. **Project profile** — `.cekernel/envs/${CEKERNEL_ENV}.env`
4. **User profile** — `~/.config/cekernel/envs/${CEKERNEL_ENV}.env`
5. **Environment variables** — explicit `export` before invocation

Profiles only fill unset variables. Explicit `export` always wins.

### Available Profiles

| Profile | Description |
|---------|-------------|
| `default.env` | Default settings for local development with WezTerm |
| `headless.env` | Terminal-free execution with higher concurrency |
| `ci.env` | CI-optimized settings with shorter timeout |

### User Profile

User-level configuration that applies across all projects. Created by `/setup`:

```
~/.config/cekernel/
  envs/
    default.env    # User defaults (e.g., CEKERNEL_VAR_DIR, CEKERNEL_BACKEND)
```

Run `/cekernel:setup` to create this interactively.

### Project Overrides

Projects can create `.cekernel/envs/` for project-specific configuration:

```
my-project/
  .cekernel/
    envs/
      default.env    # Override: CEKERNEL_BACKEND=tmux
      ci.env         # Override: CEKERNEL_MAX_PROCESSES=2
```

Custom profile names (e.g., `staging.env`) are supported — the project layer
is not limited to overriding plugin-defined profiles.

See [ADR-0006](../docs/adr/0006-env-var-catalog-and-profiles.md) for design rationale.
