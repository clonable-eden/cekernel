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
3. Set the script path based on the result:
   - If `CEKERNEL_NS=local`: `CRON_SH="$(git rev-parse --show-toplevel)/scripts/scheduler/cron.sh"`
   - If `CEKERNEL_NS=plugin`: `CRON_SH="$(dirname "$(dirname "$(which spawn-worker.sh 2>/dev/null)")")/scripts/scheduler/cron.sh"`

### Step 2: Execute Command

Pass the user's subcommand and arguments directly to `cron.sh`:

```bash
bash "$CRON_SH" register --label "ready" --schedule "0 9 * * 1-5"
bash "$CRON_SH" list
bash "$CRON_SH" cancel cekernel-cron-a1b2c3
```

### Step 3: Present Results

- For `register`: The script outputs registration details. Confirm to the user.
- For `list`: The script outputs a formatted table. Show it directly. Entries marked `[drifted]` were removed from the OS scheduler externally — suggest re-registering or cancelling.
- For `cancel`: The script confirms cancellation. Relay to the user.
- On errors: Show the error message and suggest corrective action.
