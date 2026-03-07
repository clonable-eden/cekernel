---
description: Manage one-shot scheduled jobs via OS-native schedulers (launchd on macOS, atd on Linux/WSL)
argument-hint: "<register|list|cancel> [options]"
allowed-tools: Bash, Read
---

# /at

Manage one-shot scheduled execution of cekernel dispatch. Uses OS-native schedulers (launchd on macOS, atd on Linux/WSL).

## Usage

```
/at register --schedule "<datetime>" [--label <label>] [--prompt <prompt>] [--repo <path>]
/at list
/at cancel <id>
```

Note: In plugin mode, `/cekernel:at` also works.

## Workflow

### Step 1: Detect Namespace and Determine Script Location

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set the script path based on the result:
   - If `CEKERNEL_NS=local`: `AT_SH="$(git rev-parse --show-toplevel)/scripts/scheduler/at.sh"`
   - If `CEKERNEL_NS=plugin`: `AT_SH="$(dirname "$(dirname "$(which spawn-worker.sh 2>/dev/null)")")/scripts/scheduler/at.sh"`

### Step 2: Execute Command

#### `register` — Interactive Option Builder

If the user provides all required options (`--schedule` and one of `--label`/`--prompt`), pass them directly.

If any required option is missing, **interactively ask the user** for the missing values before executing:

1. **`--label` or `--prompt`** (one required): Ask whether to use a dispatch label or a custom prompt.
   - `--label <label>` — Shorthand: generates `claude -p "/dispatch --env headless --label <label>"`
   - `--prompt <prompt>` — Arbitrary prompt string passed directly to `claude -p`
   - If both given, `--prompt` takes precedence.
2. **`--schedule`** (required): Ask for an ISO 8601 datetime. Show format examples:
   - `2026-03-15T09:00` — March 15, 2026 at 9:00 AM
   - `2026-12-31T23:59` — December 31, 2026 at 11:59 PM
   - Format: `YYYY-MM-DDThh:mm`
3. **`--repo`** (optional): Ask if the target repository is the current directory. If not, ask for the path.

Once all values are gathered, confirm the full command with the user, then execute.

#### `list` / `cancel`

Pass directly to `at.sh`:

```bash
bash "$AT_SH" register --label "ready" --schedule "2026-03-15T09:00"
bash "$AT_SH" list
bash "$AT_SH" cancel cekernel-at-a1b2c3
```

### Step 3: Present Results

- For `register`: The script outputs registration details. Confirm to the user.
- For `list`: The script outputs a formatted table. Show it directly. Entries marked `[drifted]` were removed from the OS scheduler externally — suggest re-registering or cancelling. Completed entries (with `last_run_status`) remain for diagnostics — suggest cancelling to clean up.
- For `cancel`: The script confirms cancellation. Relay to the user.
- On errors: Show the error message and suggest corrective action.
