---
description: Control and inspect running Workers and Orchestrators (systemctl for cekernel). List, suspend, resume, kill, manage priorities, and show process trees.
argument-hint: "<command> [target] [args...]"
allowed-tools: Bash, Read
---

# /orchctl

Worker control interface for cekernel — like `systemctl` / `supervisorctl`, inspects and manages running Workers across all sessions.

```
/orchctl ls | ps [--session <id>] | inspect|suspend|resume|recover|term|kill <target> | nice <target> <priority>
```

Note: In plugin mode, `/cekernel:orchctl` also works.

## Addressing: `<target>`

| Format | Example | Usage |
|--------|---------|-------|
| `<issue>` | `4` | Unique across all sessions |
| `<repo>:<issue>` | `cekernel:4` | Filter by repo name (session ID prefix) |
| `<issue> --session <id>` | `4 --session cekernel-7861a821` | Explicit session ID (for scripting) |

Try `<issue>` alone first; if multiple sessions match, show the candidates and ask the user to disambiguate.

## Workflow

### Step 1: Detect Namespace and Script Location

1. Read `skills/references/namespace-detection.md` from the repository root (`$(git rev-parse --show-toplevel)/skills/references/namespace-detection.md`). If the Read fails (file not found), you are in plugin mode.
2. Execute the detection Bash snippet from the reference file.
3. Set the script path:
   - `CEKERNEL_NS=local` → `ORCHCTL="scripts/ctl/orchctl.sh"`
   - `CEKERNEL_NS=plugin` → `ORCHCTL="$(dirname "$(dirname "$(which spawn-worker.sh 2>/dev/null || echo "")")")/scripts/ctl/orchctl.sh"`

### Step 2: Execute `bash "$ORCHCTL" <command> [args]`

| Command | Behavior | Present to user as |
|---------|----------|--------------------|
| `ls` | JSON Lines, one per Worker (`session`, `repo`, `issue`, `state`, `detail`, `priority`, `priority_name`, `elapsed`, `backend`); `no workers.` if none | Table: Session / Repo / Issue / State / Priority / Elapsed / Backend |
| `ps [--session <id>]` | Pre-formatted tree of Orchestrator sessions and their Worker/Reviewer sessions (single `claude agents --json` fetch joined with issue/phase/priority — ADR-0016 Phase 4) | As-is |
| `inspect <target>` | JSON: `session`, `issue`, `state`, `priority`, `elapsed`, `backend`, `worktree`, `checkpoint` | Structured summary, highlighting checkpoint data (phase, completed work, next steps, key decisions) |
| `suspend <target>` | Sends SUSPEND (RUNNING/WAITING/READY only); Worker checkpoints and stops at the next phase boundary | Confirm action |
| `resume <target>` | SUSPENDED (or TERMINATED with `crashed*` detail) → READY; prints the restart command | Confirm, then show the printed `spawn-worker.sh --resume` command for the user to run |
| `recover <target>` | Marks a dead RUNNING/WAITING Worker as `TERMINATED`/`crashed:detected-by-recover`; errors if the process is alive (suggest `term`/`kill`) | Confirm transition, suggest `orchctl resume` next |
| `term <target>` | Sends TERM — graceful exit at the next signal check | Confirm action |
| `kill <target>` | Immediate termination + TERMINATED (when `term` is insufficient) | Confirm action |
| `nice <target> <priority>` | Change priority: `critical` (0), `high` (5), `normal` (10), `low` (15), or numeric 0-19 (lower = higher) | Confirm action |

`ps` notes: the trailing state is the raw `claude agents --json` state (`busy`, `blocked`, `done`, ...); `missing` = no longer listed. **`blocked` means stalled on a permission dialog — surface it prominently.** Sessions spawned by an interactive Orchestrator have no `orchestrator` row, but their Worker/Reviewer rows still appear.

Crash recovery sequence: `health-check.sh` (detect zombie) → `orchctl recover` → `orchctl resume` → `spawn-worker.sh --resume`.
