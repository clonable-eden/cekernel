---
description: Manage recurring schedules via OS-native schedulers (launchd on macOS, crontab on Linux/WSL)
argument-hint: "<register|list|cancel> [options]"
allowed-tools: Bash, Read
---

# /cron

Manage recurring scheduled execution of cekernel dispatch. Uses OS-native schedulers (launchd on macOS, crontab on Linux/WSL).

## Usage

```
/cron register --schedule "<cron-expr>" [--label <label>] [--prompt <prompt>] [--repo <path>]
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

#### `register` — Interactive Option Builder

If the user provides all required options (`--label` and `--schedule`), pass them directly.

If any required option is missing, **interactively ask the user** for the missing values before executing:

1. **`--label` or `--prompt`** (one required): Ask whether to use a dispatch label or a custom prompt.
   - `--label <label>` — Shorthand: generates `claude -p "/dispatch --env headless --label <label>"`
   - `--prompt <prompt>` — Arbitrary prompt string passed directly to `claude -p`
   - If both given, `--prompt` takes precedence.
2. **`--schedule`** (required): Ask for a cron expression. Show common examples to help the user:
   - `0 9 * * 1-5` — Weekdays at 9:00 AM
   - `0 9 * * *` — Every day at 9:00 AM
   - `30 */6 * * *` — Every 6 hours at :30
   - `0 0 * * 0` — Every Sunday at midnight
   - Format: `minute hour day-of-month month day-of-week`
3. **`--repo`** (optional): Ask if the target repository is the current directory. If not, ask for the path.

Once all values are gathered, confirm the full command with the user, then execute.

#### `list` / `cancel`

Pass directly to `cron.sh`:

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
