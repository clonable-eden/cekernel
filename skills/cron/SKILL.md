---
description: Manage recurring schedules via OS-native schedulers (launchd on macOS, crontab on Linux/WSL)
argument-hint: "<register|list|cancel> [options]"
allowed-tools: Bash, Read
---

# /cron

Manage recurring scheduled execution of cekernel dispatch. Uses OS-native schedulers (launchd on macOS, crontab on Linux/WSL).

## Usage

```
/cron register --label <label> --schedule "<cron-expr>" [--repo <path>]
/cron list
/cron cancel <id>
```

Note: In plugin mode, `/cekernel:cron` also works.

## Workflow

### Step 1: Detect Namespace and Determine Script Location

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set the script directory based on the result:
   - If `CEKERNEL_NS=local`: `SCHED_DIR="$(git rev-parse --show-toplevel)/scripts/scheduler"`
   - If `CEKERNEL_NS=plugin`: Locate via installed plugin path, e.g. `SCHED_DIR="$(dirname "$(dirname "$(which spawn-worker.sh 2>/dev/null)")")/scripts/scheduler"`

### Step 2: Parse User Command and Execute

#### register — Register a recurring schedule

**Required arguments:**
- `--label <label>` — Issue label to dispatch (e.g., `ready`)
- `--schedule "<cron-expr>"` — Cron expression (5 fields: `minute hour day-of-month month day-of-week`)

**Optional arguments:**
- `--repo <path>` — Target repository (default: current working directory)

**Procedure:**

```bash
# 1. Source scripts
source "${SCHED_DIR}/preflight.sh"
source "${SCHED_DIR}/registry.sh"
source "${SCHED_DIR}/wrapper.sh"
source "${SCHED_DIR}/cron-backend.sh"

# 2. Set variables
REPO="${REPO:-$(pwd)}"
BACKEND=$(cron_backend_detect)
ID="cekernel-cron-$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"

# 3. Preflight check
schedule_preflight_check cron "$REPO"

# 4. Generate wrapper script
schedule_generate_wrapper "$ID" "$REPO" "$PATH" "$LABEL"
RUNNER="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}/runners/${ID}.sh"

# 5. Register with OS scheduler
cron_backend_register "$ID" "$SCHEDULE" "$RUNNER"

# 6. Add to registry
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ENTRY=$(jq -n \
  --arg id "$ID" \
  --arg type "cron" \
  --arg schedule "$SCHEDULE" \
  --arg label "$LABEL" \
  --arg repo "$REPO" \
  --arg path "$PATH" \
  --arg os_backend "$BACKEND" \
  --arg os_ref "$ID" \
  --arg created_at "$CREATED_AT" \
  '{id: $id, type: $type, schedule: $schedule, label: $label, repo: $repo, path: $path, os_backend: $os_backend, os_ref: $os_ref, created_at: $created_at, last_run_at: null, last_run_status: null}')
schedule_registry_add "$ENTRY"
```

On success, display:
```
Registered: <ID>
  Schedule:  <cron-expr>
  Label:     <label>
  Repo:      <repo>
  Backend:   <launchd|crontab>
  Runner:    <runner-path>
```

If any step fails, clean up partial state (remove runner, remove OS entry if created) and report the error.

#### list — List all cron schedules

**Procedure:**

```bash
source "${SCHED_DIR}/registry.sh"
source "${SCHED_DIR}/cron-backend.sh"

# Get cron entries
ENTRIES=$(schedule_registry_list --type cron)
```

For each entry, check drift by calling `cron_backend_is_registered <os_ref>`. If the OS scheduler no longer has the entry, mark it as `[drifted]`.

Format output as a table:

```
ID                      Schedule       Label   Repo              Last Run              Status
cekernel-cron-a1b2c3    0 9 * * 1-5    ready   project-alpha     2026-03-02T09:00:12Z  success
cekernel-cron-x4y5z6    */30 * * * *   check   cekernel          (never)               -        [drifted]
```

If no entries exist, display: `No cron schedules registered.`

#### cancel — Cancel a cron schedule

**Required arguments:**
- `<id>` — Schedule ID (from `list` output)

**Procedure:**

```bash
source "${SCHED_DIR}/registry.sh"
source "${SCHED_DIR}/cron-backend.sh"

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-/usr/local/var/cekernel}"

# 1. Verify entry exists
schedule_registry_get "$ID"

# 2. Remove from OS scheduler
cron_backend_cancel "$ID"

# 3. Remove runner script
rm -f "${CEKERNEL_VAR_DIR}/runners/${ID}.sh"

# 4. Remove from registry
schedule_registry_remove "$ID"
```

On success, display: `Cancelled: <ID>`

If the ID does not exist in the registry, report the error and suggest running `/cron list`.

### Step 3: Present Results

- For `register`: Confirm registration with details
- For `list`: Format as a readable table with drift status
- For `cancel`: Confirm cancellation
- Always show errors clearly with actionable guidance
