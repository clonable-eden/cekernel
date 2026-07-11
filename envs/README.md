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
| `CEKERNEL_WATCH_CHUNK_TIMEOUT` | `540` | Positive integer (seconds) | `watch.sh` | Max seconds per `watch.sh` invocation before returning a `watching` sentinel (exit 0). Must be shorter than the Bash tool's 600s hard limit to avoid SIGTERM. The Orchestrator re-calls `watch.sh` on a `watching` result; cumulative elapsed is computed from the Worker's `.spawned` timestamp (#630) |
| `CEKERNEL_STATE_POLL_INTERVAL` | `5` | Positive integer (seconds) | `watch.sh` | State file poll interval (local fs read — cheap). Completion latency is bounded by this value (ADR-0020 Phase 1: polling split) |
| `CEKERNEL_POLL_INTERVAL` | `30` | Positive integer (seconds) | `watch.sh` | Backend verdict poll interval (`claude agents --json` — spawns a process, heavier). Controls how often `watch.sh` checks backend liveness (ADR-0020 Phase 1: polling split) |
| `CEKERNEL_WATCH_QUERY_RETRY_MAX` | `3` | Positive integer | `watch.sh` | Consecutive unverifiable liveness polls (`query-failed` / `unknown-value` verdicts, ADR-0018) tolerated before watch escalates an `error` result. The escalation detail warns the Worker may still be running — do not clean up on this result alone |
| `CEKERNEL_CHECKPOINT_FILENAME` | `.cekernel-checkpoint.md` | Any filename | `checkpoint-file.sh` | Checkpoint file name in worktree |
| `CEKERNEL_TASK_FILENAME` | `.cekernel-task.md` | Any filename | `task-file.sh` | Task file name in worktree |
| `CEKERNEL_CI_CHUNK_TIMEOUT` | `540` | Positive integer (seconds) | `wait-ci.sh` | Max seconds per `wait-ci.sh` invocation before returning a `watching` sentinel (exit 0). Must be shorter than the Bash tool's 600s hard limit to avoid SIGTERM. The Worker re-calls `wait-ci.sh` on a `watching` result (#650) |
| `CEKERNEL_CI_MAX_RETRIES` | `3` | Positive integer | `worker.md` (Phase 3) | Maximum CI retry attempts before Worker reports failure |
| `CEKERNEL_AUTO_MERGE` | `false` | `true`, `false` | Orchestrator | `true`: Orchestrator auto-merges after Reviewer approval. `false`: desktop notification only, human merges manually |
| `CEKERNEL_KEEP_WORKTREE` | `false` | `true`, `false` | `cleanup-worktree.sh` | `true`: preserve the worktree and local branch on cleanup (Worker is still killed, IPC still removed). `--force` always removes regardless. Useful with `CEKERNEL_AUTO_MERGE=false` for manual pre-merge verification |
| `CEKERNEL_REVIEW_MAX_RETRIES` | `2` | Positive integer | Orchestrator | Max cycles of Reviewer reject → Worker re-implement. Escalates to human when exceeded |
| `CEKERNEL_NOTIFY_MACOS_ACTION` | `none` | `none`, `open`, `pbcopy` | `desktop-notify-backend/macos.sh` | macOS notification URL action: `none` = notify only, `open` = open URL in browser, `pbcopy` = copy URL to clipboard |
| `CEKERNEL_VAR_DIR` | `~/.local/var/cekernel` | Directory path | `registry.sh`, `wrapper.sh` | Runtime state directory (locks, logs, runners, registry) |
| `CEKERNEL_SCHEDULE_POLL_INTERVAL` | `15` | Positive integer (seconds) | `wrapper.sh` | Poll interval for the scheduled runner's `agents --json` supervision loop (ADR-0016 Phase 3). Captured at schedule time — exported env vars do not reach the cron/at runtime |
| `CEKERNEL_SCHEDULE_POLL_TIMEOUT` | `3600` | Positive integer (seconds) | `wrapper.sh` | Poll window before a scheduled run is recorded as `error` with state `timeout` (ADR-0016 Phase 3). On timeout the background session is left running — only the registry outcome is affected. Raise for long `/dispatch` runs. Captured at schedule time |
| `CEKERNEL_FALLBACK_MODEL` | (unset) | Claude model name (e.g. `claude-haiku-4-5-20251001`) | `bare-mode.sh` (all spawn paths), `spawn.sh` (`--fallback-model` flag) | Forwarded to `claude` as `--fallback-model <model>`: automatic fallback to a smaller model when the primary model is unavailable (e.g. quota exhaustion). Safety valve for unattended runs — `headless.env` sets a default; interactive profiles leave it unset (opt-in). Unset: no flag is added (existing behavior). `spawn.sh --fallback-model` overrides the env/profile value |
| `CEKERNEL_DISABLE_STOP_GUARD` | (unset) | `1` to disable | `worker-stop-guard.sh` (plugin Stop hook, ADR-0018) | `1`: disable the Worker lifecycle Stop hook guard. Set in the environment of a session running inside a Worker worktree (e.g. a human debugging interactively) to stop the guard from injecting continue-the-protocol feedback on every turn end |
| `CEKERNEL_CLAUDE_SETTINGS` | (unset) | Path to a Claude settings JSON | `bare-mode.sh` (all spawn paths) | Passed to `claude` via `--settings`. `--bare` is conditional on auth availability (ADR-0016 Amendment 1): when `ANTHROPIC_API_KEY` or this variable is set, spawns run in `--bare` mode (which never reads OAuth/keychain — auth is strictly `ANTHROPIC_API_KEY` or `apiKeyHelper` via this settings file); otherwise interactive spawns drop `--bare` and authenticate via OAuth/keychain, emitting a one-line stderr notice. **Required for cron/at scheduled jobs**, where exported env vars do not reach the generated runner (the path is captured at schedule time) — scheduled-job generation fails fast when neither auth source is available |

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
| `headless.env` | Terminal-free execution (headless backend, 5 children, 3600s timeout, fallback model enabled for unattended runs) |

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
