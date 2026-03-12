# ADR-0006: Centralized Environment Variable Catalog and Profiles

## Status

Accepted

## Context

cekernel's configurable behavior is driven by `CEKERNEL_*` environment variables, each defaulted via the `${VAR:-default}` pattern in individual scripts. As the project has grown through Layer 0 and Layer 1 (ADR-0001 through ADR-0005), the number of variables has reached 8:

| Variable | Default | User-configurable | Used by |
|----------|---------|:-:|---------|
| `CEKERNEL_BACKEND` | `wezterm` | Yes | `backend-adapter.sh` |
| `CEKERNEL_SESSION_ID` | auto-generated | No | `session-id.sh` → all scripts |
| `CEKERNEL_IPC_DIR` | derived from SESSION_ID | No | `session-id.sh` → all scripts |
| `CEKERNEL_MAX_WORKERS` | `3` | Yes | `spawn-worker.sh` |
| `CEKERNEL_WORKER_TIMEOUT` | `3600` | Yes | `watch-worker.sh`（現 `watch.sh`）|
| `CEKERNEL_CHECKPOINT_FILENAME` | `.cekernel-checkpoint.md` | Yes | `checkpoint-file.sh` |
| `CEKERNEL_TASK_FILENAME` | `.cekernel-task.md` | Yes | `task-file.sh` |
| `CEKERNEL_ACTIVE_BACKEND` | derived from BACKEND | No | `backend-adapter.sh` (internal) |

These variables are scattered across individual scripts with no central documentation. A user wanting to customize cekernel must read each script's source to discover available knobs and their defaults.

Additionally, common configurations recur: "local dev with WezTerm", "headless CI", "tmux over SSH". Each requires setting multiple variables consistently.

### Plugin context

cekernel is distributed as a Claude Code plugin. When installed via `/plugin install cekernel@clonable-eden-plugins`, the plugin files reside in the Claude Code plugin directory (`.claude/plugins/` hierarchy). Files within it are **overwritten on `/plugin update`** — users should not edit plugin-internal files for project-specific configuration.

This creates a tension: the plugin ships sensible defaults, but each project may need different settings (e.g., one project uses WezTerm, another uses headless for CI). Configuration must live in a place that survives plugin updates and is scoped to the project.

### Key observation

All user-configurable variables are consumed by **Orchestrator-side scripts** (`spawn-worker.sh`, `watch-worker.sh`, `backend-adapter.sh`, etc.). The Worker agent receives only `CEKERNEL_SESSION_ID` (auto-generated), which it uses to derive `CEKERNEL_IPC_DIR` for IPC file paths. **No user-configurable environment variable needs to reach the Worker agent.** Therefore, env profiles need only be loaded by the `/orchestrate` skill and the Orchestrator agent.

## Decision

### 1. Environment variable catalog (`envs/README.md`)

Create a single reference document listing all `CEKERNEL_*` variables:

```
envs/
  README.md           # Catalog: every variable, default, purpose, used-by
```

Each entry includes: variable name, default value, valid values (if enumerated), purpose, and which script consumes it. This file is the single source of truth for "what can I configure?"

When a new variable is introduced in any script, it must be added to the catalog.

### 2. Environment profiles (`envs/*.env`)

Named `.env` files containing coherent sets of variable assignments:

```
envs/
  README.md
  default.env         # CEKERNEL_BACKEND=wezterm  CEKERNEL_MAX_WORKERS=3
  headless.env        # CEKERNEL_BACKEND=headless  CEKERNEL_MAX_WORKERS=5
  ci.env              # CEKERNEL_BACKEND=headless  CEKERNEL_WORKER_TIMEOUT=1800
```

Format: standard shell-sourceable `KEY=VALUE` lines (no `export`, no quotes unless needed). One variable per line. Comments with `#`.

```bash
# headless.env — Terminal-free execution for CI/cron
CEKERNEL_BACKEND=headless
CEKERNEL_MAX_WORKERS=5
CEKERNEL_WORKER_TIMEOUT=1800
```

Profiles are intentionally **partial** — they only set variables that differ from defaults. Unset variables fall through to script-level `${VAR:-default}`.

### 3. Profile loading with multi-layer search

The `/orchestrate` skill's Step 2 and the Orchestrator agent source profiles at startup using a two-layer search order:

| Layer | Path | Provider | Survives update |
|-------|------|----------|:-:|
| Plugin defaults | `envs/${CEKERNEL_ENV}.env` | cekernel plugin | No (`/plugin update` overwrites) |
| Project override | `.cekernel/envs/${CEKERNEL_ENV}.env` | Project developer | Yes (git-managed) |

The full priority order (lowest to highest):

1. **Script defaults** — `${VAR:-default}` in each script (lowest priority)
2. **Plugin profile** — `envs/${CEKERNEL_ENV}.env`
3. **Project profile** — `.cekernel/envs/${CEKERNEL_ENV}.env`
4. **Environment variables** — explicitly `export`-ed before invocation (highest priority)

Profiles only fill in values that are **not already set** in the environment. This follows the Unix convention: explicit user intent (environment variable) always wins over defaults (profile files).

```bash
CEKERNEL_ENV="${CEKERNEL_ENV:-default}"

# Load profile defaults (only sets unset variables)
_cekernel_load_env() {
  local env_file="$1"
  if [[ -f "$env_file" ]]; then
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue  # skip comments and empty lines
      if [[ -z "${!key:-}" ]]; then                     # only set if not already in env
        export "$key=$value"
      fi
    done < "$env_file"
  fi
}

# Layer 1: Project override (checked first, but only fills unset vars)
_cekernel_load_env ".cekernel/envs/${CEKERNEL_ENV}.env"

# Layer 2: Plugin defaults (fills remaining unset vars)
_cekernel_load_env "${_LOAD_ENV_DIR}/../../envs/${CEKERNEL_ENV}.env"
```

Note the reversed source order: project profile is loaded **first** because it fills in unset variables. Any variable set by the project profile will not be overwritten by the plugin profile. Any variable set via `export` before invocation will not be overwritten by either profile.

The profile name is selected via `CEKERNEL_ENV` environment variable (default: `default`). This creates a three-level configuration:

1. `CEKERNEL_ENV=headless` selects the profile name (meta-policy)
2. Plugin's `headless.env` provides curated defaults (policy: plugin author's recommendation)
3. Project's `headless.env` overrides plugin defaults for specific values (policy: project-specific needs)
4. Explicit `export CEKERNEL_MAX_WORKERS=2` overrides everything (user intent)

Worker agents do **not** load profiles. They inherit only `CEKERNEL_SESSION_ID` from the Orchestrator's environment, which is sufficient for all Worker-side IPC operations.

### 4. Project-level configuration directory

Projects using cekernel can create `.cekernel/envs/` for project-specific overrides:

```
my-project/
  .cekernel/
    envs/
      default.env       # Override: CEKERNEL_BACKEND=tmux for this project
      ci.env            # Override: CEKERNEL_MAX_WORKERS=2 for CI
  .claude/
    settings.json       # Claude Code settings (separate namespace)
```

`.cekernel/` is the cekernel-specific configuration namespace, distinct from `.claude/` (Claude Code itself). Whether to git-track `.cekernel/` is a project decision — shared team configurations should be tracked, personal preferences should be `.gitignore`d.

Users can also create custom profile names (e.g., `.cekernel/envs/staging.env`) that don't exist in the plugin — the project layer is not limited to overriding plugin-defined profiles.

### UNIX Philosophy Alignment

> **Rule of Representation**: *"Fold knowledge into data so program logic can be stupid and robust."*

Configuration knowledge moves from scattered `${VAR:-default}` patterns (code) to centralized `.env` files (data). Scripts remain unchanged — they still read `${VAR:-default}` — but the human-facing configuration is now in data files rather than source code.

> **Rule of Transparency**: *"Design for visibility to make inspection and debugging easier."*

The catalog (`envs/README.md`) makes all knobs visible in one place. Before this change, discovering `CEKERNEL_WORKER_TIMEOUT` required reading `watch-worker.sh`. After, it's in the catalog. The `.env` files also serve as documentation of tested, coherent configurations.

> **Rule of Separation**: *"Separate policy from mechanism; separate interfaces from engines."*

The env profile is policy ("we're running in CI, so use headless with 1800s timeout"). The scripts are mechanism ("read CEKERNEL_WORKER_TIMEOUT and apply it to FIFO read"). These already existed separately, but the profile file makes the policy explicit and named rather than ad-hoc `export` commands.

> **Rule of Least Surprise**: *"In interface design, always do the least surprising thing."*

`.env` files are a universally recognized convention. `source .env` is familiar to any shell user. No custom configuration format, no YAML/TOML parser, no schema language. The profile system adds no new concepts beyond "source a file".

## Alternatives Considered

### Alternative: JSON/YAML configuration file

Use a structured configuration file (`cekernel.json` or `cekernel.yaml`) with nested keys, validation, and schema.

Rejected:

> Rule of Simplicity: *"Design for simplicity; add complexity only where you must."*

cekernel has 5 user-configurable variables. A JSON/YAML configuration system requires a parser, a schema, a loader, and error handling for malformed files. `.env` files are `source`-d in one line and require zero dependencies. The complexity is grossly disproportionate to the configuration surface.

> Rule of Composition: *"Design programs to be connected with other programs."*

`.env` files are shell-native. They compose with `source`, `grep`, `sed`, `env`. JSON requires `jq`. YAML requires a YAML parser. The `.env` approach has zero external dependencies.

### Alternative: Centralized defaults file (single `defaults.env` instead of profiles)

Define all defaults in one file, let users override via environment variables. No named profiles.

This is simpler but loses the "named configuration" benefit. A user running CI must remember to set 3 variables correctly every time. Named profiles capture tested, coherent configurations that can be referenced by name. The marginal cost of supporting profiles (one `case` branch or file lookup) is low.

### Alternative: Load profiles in every script

Instead of loading at the skill/orchestrator level, have each script source the profile independently.

Rejected:

> Rule of Parsimony: *"Write a big program only when it is clear by demonstration that nothing else will do."*

Loading once at the Orchestrator level propagates to all child scripts via the environment. Loading in every script is redundant and risks inconsistency if scripts source different profiles. The Orchestrator is the natural configuration boundary — it's where the session begins.

## Integration Points

### Propagation Chain

The env profile mechanism requires wiring at specific points in the execution chain:

```
/cekernel:orchestrate --env headless #108
  → skill (SKILL.md): parses --env argument, defaults to "default"
    → skill includes CEKERNEL_ENV=headless in orchestrator agent prompt
      → orchestrator agent: passes export CEKERNEL_ENV=headless before spawn-worker.sh
        → spawn-worker.sh: sources load-env.sh early (before other shared helpers)
          → load-env.sh: reads headless.env, exports CEKERNEL_BACKEND=headless etc.
            → remaining spawn-worker.sh logic uses configured values
```

### Scripts That Source `load-env.sh`

| Script | Role | Why |
|--------|------|-----|
| `spawn-worker.sh` | Only integration point | All user-configurable vars are consumed by Orchestrator-side scripts. Loading once at spawn time propagates to backend-adapter, concurrency guard, etc. via the environment. |

`load-env.sh` is sourced immediately after `session-id.sh` and before other shared helpers, ensuring that profile values are available when `backend-adapter.sh`, `worker-state.sh`, etc. are loaded.

### Why Not Load in Other Scripts

Per the "Key observation" in the Context section, all user-configurable variables are consumed by Orchestrator-side scripts. Worker agents inherit only `CEKERNEL_SESSION_ID`. Therefore:

- `watch-worker.sh`, `cleanup-worktree.sh`, `health-check.sh` — These run in the Orchestrator's shell where `CEKERNEL_ENV` is already exported. They use `${VAR:-default}` which is sufficient since `spawn-worker.sh` already set the environment.
- Worker-side scripts — Do not need profile loading; they only use `CEKERNEL_SESSION_ID`.

### Skill UX

The `/cekernel:orchestrate` skill accepts `--env <profile>` as an optional argument (via `argument-hint` frontmatter). When unspecified, `default` is used. The skill passes the profile name to the Orchestrator agent's prompt, which in turn exports it before each `spawn-worker.sh` call.

## Consequences

### Positive

- Single reference document for all configuration knobs (currently undiscoverable without reading source)
- Named profiles for common scenarios (local dev, headless, CI) — shareable and version-controlled
- Project-level overrides survive `/plugin update` and can be git-managed per project
- Users can define custom profiles (e.g., `staging.env`) without modifying the plugin
- Zero changes to existing scripts — they continue to use `${VAR:-default}`, unaware of profiles
- Profile format (`.env`) is universally understood, requires no tooling

### Negative

- One more directory (`envs/`) and 3-4 files to maintain
- Catalog must be kept in sync with script changes — a manual discipline (no automated enforcement)
- `CEKERNEL_ENV` adds yet another environment variable to the mix (meta-configuration)

### Trade-offs

**Discoverability vs. simplicity**: The catalog and profiles add files that didn't exist before. However, the configuration already exists — it's just hidden in script source. The cost is a small maintenance burden; the benefit is that a user can `cat envs/README.md` instead of `grep CEKERNEL_ scripts/**/*.sh`.

**Named profiles vs. ad-hoc exports**: Profiles impose a small amount of structure (predefined `.env` files). Users who prefer `export CEKERNEL_BACKEND=headless` can continue to do so — profiles only fill unset variables, never overwrite explicit environment settings. This ensures user intent always wins.

**Plugin defaults vs. project overrides**: The two-layer search adds complexity over a single-layer approach. However, the alternative — editing plugin-internal files — is fragile (`/plugin update` destroys changes) and surprising (configuration lives outside the project). The two-layer model follows the Unix convention and costs only one additional `if [[ -f ... ]]; then source ...; fi` block.

## Amendments

### 2026-02-28: Remove CLAUDE_PLUGIN_ROOT dependency (#132)

`CLAUDE_PLUGIN_ROOT` is set by Claude Code only when executed via a skill, making it unreliable in shell scripts. `load-env.sh` now resolves the plugin envs directory via `BASH_SOURCE[0]` (`_LOAD_ENV_DIR`), following the same pattern as `backend-adapter.sh` (`_BACKEND_ADAPTER_DIR`). All references to `CLAUDE_PLUGIN_ROOT` in this ADR have been updated to reflect the new path resolution.

### 2026-02-28: Worker-side profile loading (ADR-0010)

The key observation in the Context section — "No user-configurable environment variable needs to reach the Worker agent" — is amended by [ADR-0010](./0010-worker-env-profile-loading.md). Workers now receive `CEKERNEL_ENV` (profile name) via the launch prompt and source `load-env.sh` on demand to read Worker-side configuration (e.g., `CEKERNEL_CI_MAX_RETRIES`). The profile mechanism, loading order, and `.env` format remain unchanged. See ADR-0010 for details.
