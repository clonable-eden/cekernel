---
description: Control and inspect running Workers (systemctl for cekernel). List, suspend, resume, kill, and manage priorities.
argument-hint: "<command> [target] [args...]"
allowed-tools: Bash, Read
---

# /orchctrl

Worker control interface for cekernel. Like `systemctl` / `supervisorctl`, provides commands to inspect and manage running Workers across all sessions.

## Usage

```
/orchctrl ls
/orchctrl log <target>
/orchctrl inspect <target>
/orchctrl suspend <target>
/orchctrl resume <target>
/orchctrl term <target>
/orchctrl kill <target>
/orchctrl nice <target> <priority>
```

Note: In plugin mode, `/cekernel:orchctrl` also works.

## Addressing: `<target>`

All commands except `ls` require a `<target>` to identify the Worker.

| Format | Example | Usage |
|--------|---------|-------|
| `<issue>` | `4` | Unique across all sessions |
| `<repo>:<issue>` | `glimmer:4` | Filter by repo name |
| `<issue> --session <id>` | `4 --session glimmer-7861a821` | Explicit session ID |

Rules:
- Try `<issue>` alone first; if unique, execute
- If multiple matches, show candidates and ask the user to disambiguate
- `<repo>:<issue>` filters by the repo name prefix of the session ID
- `--session` specifies the full session ID (for scripting)

## Workflow

### Step 1: Detect Namespace and Determine Script Location

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set the script path based on the result:
   - If `CEKERNEL_NS=local`: `ORCHCTRL="scripts/orchestrator/orchctrl.sh"`
   - If `CEKERNEL_NS=plugin`: `ORCHCTRL="$(dirname "$(dirname "$(which spawn-worker.sh 2>/dev/null || echo "")")")/scripts/orchestrator/orchctrl.sh"`

### Step 2: Parse User Command and Execute

Run `orchctrl.sh` via Bash with the user's command.

#### ls — List all Workers

```bash
bash "$ORCHCTRL" ls
```

Output: JSON Lines (one per Worker). Fields: `session`, `repo`, `issue`, `state`, `detail`, `priority`, `priority_name`, `elapsed`, `backend`, `log`.

If no workers are found, outputs `no workers.`

Format the output as a readable table for the user:

| Session | Repo | Issue | State | Priority | Elapsed | Backend | Log |
|---------|------|-------|-------|----------|---------|---------|-----|

#### log — Tail Worker log

```bash
bash "$ORCHCTRL" log <target>
```

Shows the last 100 lines of the Worker's log file. Saves the user from searching for log file locations in `/tmp/cekernel-ipc/`.

#### inspect — Detailed Worker view

```bash
bash "$ORCHCTRL" inspect <target>
```

Output: JSON with `session`, `issue`, `state`, `priority`, `elapsed`, `backend`, `worktree`, `checkpoint`, `logs`.

Present the output in a human-readable format, especially the checkpoint data (current phase, completed work, next steps, key decisions).

#### suspend — Suspend a Worker

```bash
bash "$ORCHCTRL" suspend <target>
```

Sends a SUSPEND signal. Only works for Workers in RUNNING, WAITING, or READY state. The Worker will checkpoint its progress and stop at the next phase boundary.

#### resume — Resume a suspended Worker

```bash
bash "$ORCHCTRL" resume <target>
```

Only works for Workers in SUSPENDED state. Changes state to READY and outputs the command to restart:

```bash
export CEKERNEL_SESSION_ID=<session-id> && spawn-worker.sh --resume <issue>
```

After orchctrl confirms the state change, run `spawn-worker.sh --resume` to actually restart the Worker process.

#### term — Graceful shutdown

```bash
bash "$ORCHCTRL" term <target>
```

Sends a TERM signal. The Worker will finish its current step, clean up, and exit gracefully at the next signal check.

#### kill — Force kill

```bash
bash "$ORCHCTRL" kill <target>
```

Immediately terminates the Worker process and marks it as TERMINATED. Use when `term` is insufficient (Worker is hung or unresponsive).

#### nice — Change priority

```bash
bash "$ORCHCTRL" nice <target> <priority>
```

Changes the Worker's priority. Priority values: `critical` (0), `high` (5), `normal` (10), `low` (15), or numeric `0-19` (lower = higher priority, like Unix `nice`).

### Step 3: Present Results

- For `ls`: Format as a table
- For `inspect`: Format as a structured summary
- For `log`: Show the log content directly
- For action commands (`suspend`, `resume`, `term`, `kill`, `nice`): Confirm the action was taken
- For `resume`: Also show the follow-up `spawn-worker.sh --resume` command for the user to execute
