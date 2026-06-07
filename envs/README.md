# Environment Variable Catalog

All `CEKERNEL_*` environment variables used by cekernel.

## User-configurable Variables

These can be set via env profiles or explicit `export`.

| Variable | Default | Valid Values | Used by | Purpose |
|----------|---------|-------------|---------|---------|
| `CEKERNEL_BACKEND` | `headless` | `wezterm`, `tmux`, `headless` | `backend-adapter.sh` | Select Worker process backend |
| `CEKERNEL_MAX_ORCHESTRATORS` | `3` | Positive integer | `dispatch`, `orchestrate` | Maximum number of concurrently running orchestrators |
| `CEKERNEL_MAX_ORCH_CHILDREN` | `5` | Positive integer | `spawn.sh` | Maximum concurrent children (workers + reviewers) per orchestrator |
| `CEKERNEL_WORKER_TIMEOUT` | `3600` | Positive integer (seconds) | `watch.sh` | Worker timeout before auto-termination |
| `CEKERNEL_CHECKPOINT_FILENAME` | `.cekernel-checkpoint.md` | Any filename | `checkpoint-file.sh` | Checkpoint file name in worktree |
| `CEKERNEL_TASK_FILENAME` | `.cekernel-task.md` | Any filename | `task-file.sh` | Task file name in worktree |
| `CEKERNEL_CI_MAX_RETRIES` | `3` | Positive integer | `worker.md` (Phase 3) | Maximum CI retry attempts before Worker reports failure |
| `CEKERNEL_AUTO_MERGE` | `false` | `true`, `false` | Orchestrator | `true`: Orchestrator auto-merges after Reviewer approval. `false`: desktop notification only, human merges manually |
| `CEKERNEL_REVIEW_MAX_RETRIES` | `2` | Positive integer | Orchestrator | Max cycles of Reviewer reject → Worker re-implement. Escalates to human when exceeded |
| `CEKERNEL_NOTIFY_MACOS_ACTION` | `none` | `none`, `open`, `pbcopy` | `desktop-notify-backend/macos.sh` | macOS notification URL action: `none` = notify only, `open` = open URL in browser, `pbcopy` = copy URL to clipboard |
| `CEKERNEL_VAR_DIR` | `~/.local/var/cekernel` | Directory path | `registry.sh`, `wrapper.sh` | Runtime state directory (locks, logs, runners, registry) |

## Internal Variables

Auto-generated or derived. Not intended for user configuration.

| Variable | Default | Used by | Purpose |
|----------|---------|---------|---------|
| `CEKERNEL_SESSION_ID` | Auto-generated (`{repo}-{hex8}`) | `session-id.sh` -> all scripts | Session namespace for IPC |
| `CEKERNEL_IPC_DIR` | `~/.local/var/cekernel/ipc/${SESSION_ID}` | `session-id.sh` -> all scripts | IPC directory path |
| `CEKERNEL_ACTIVE_BACKEND` | Derived from `CEKERNEL_BACKEND` | `backend-adapter.sh` (internal) | Resolved backend name |
| `CEKERNEL_TERM_GRACE_PERIOD` | `120` | `orchestrator.md` | Grace period (seconds) after TERM before force-kill |
| `CEKERNEL_MIN_RUNTIME` | `300` | `orchestrator.md` | Minimum runtime (seconds) before Worker can be suspended |

## Meta Variable

| Variable | Default | Used by | Purpose |
|----------|---------|---------|---------|
| `CEKERNEL_ENV` | `default` | `load-env.sh` | Select which env profile to load |

## Notes on bare mode auth

`CEKERNEL_USE_BARE=true` opts the headless backend into Claude Code's `--bare`
mode. `--bare` strips Claude Code of all interactive amenities, which has
important authentication consequences worth calling out separately from the
variable table.

- **`--bare` does not read OAuth / keychain credentials.** Per the
  [Claude Code CLI reference](https://docs.claude.com/en/docs/claude-code/cli-reference),
  `--bare` runs without the interactive session that owns the OAuth token and
  the OS keychain entries, so any auth state established by `claude login`
  is invisible to a `--bare` invocation.
- **An explicit API key source is mandatory.** Either set `ANTHROPIC_API_KEY`
  in the environment, or supply a settings file with an `apiKeyHelper` via
  `--settings <path>`. Without one of these, `--bare` will fail to
  authenticate.
- **Preflight auto-disables when no key is available.** cekernel's headless
  preflight checks for a usable `ANTHROPIC_API_KEY` / `apiKeyHelper` before
  launching. When neither is configured, it emits a warning on stderr,
  disables `--bare` for that invocation, and falls back to the standard
  `claude -p` path so the run still proceeds.
- **Recommended use cases.** Enable `CEKERNEL_USE_BARE=true` from
  programmatic-batch contexts where `ANTHROPIC_API_KEY` can be supplied
  explicitly — typically the `/cron` and `/at` scheduled jobs, CI pipelines,
  and other non-interactive automation. Leave it off for ordinary
  developer-driven sessions that rely on the OAuth login.

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
| `default.env` | Symlink to `headless.env` (loaded when `CEKERNEL_ENV` is unset or `default`) |
| `wezterm.env` | WezTerm backend with standard concurrency |
| `tmux.env` | tmux backend with standard concurrency |
| `headless.env` | Terminal-free execution (headless backend, 5 children, 3600s timeout) |

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
      default.env    # Override: CEKERNEL_BACKEND=wezterm
      wezterm.env    # Override: CEKERNEL_MAX_ORCH_CHILDREN=2
```

Custom profile names (e.g., `staging.env`) are supported — the project layer
is not limited to overriding plugin-defined profiles.

See [ADR-0006](../docs/adr/0006-env-var-catalog-and-profiles.md) for design rationale.
