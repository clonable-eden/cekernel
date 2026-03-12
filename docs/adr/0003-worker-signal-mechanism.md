# ADR-0003: Signal mechanism for asynchronous Worker control

## Status

Accepted

## Context

cekernel's Worker control is currently **unidirectional and binary**:

```
Orchestrator → Worker:  spawn (one-time, at birth)
Worker → Orchestrator:  notify-complete via FIFO (one-time, at death)
```

Between spawn and completion, there is no communication channel from Orchestrator to Worker. The Orchestrator can detect problems (`health-check.sh` finds zombies, `watch-worker.sh`（現 `watch.sh`）detects timeouts) but cannot act on them — it can only kill the terminal pane (`cleanup-worktree.sh`), which is the equivalent of `SIGKILL`: immediate, ungraceful, no cleanup by the Worker.

This creates three operational gaps:

1. **No graceful cancellation**: If an issue's direction changes mid-implementation, the only option is to kill the Worker's pane. Any uncommitted work is lost. Any half-created PR is left dangling.

2. **No preemption**: When a high-priority issue arrives and all Worker slots are full, there is no way to ask a low-priority Worker to yield. The Orchestrator must wait for natural completion or force-kill.

3. **No coordinated shutdown**: When the user wants to stop all Workers (e.g., end of day, switching context), each Worker must be individually killed. Workers cannot commit progress and exit cleanly.

In Unix terms, cekernel has `kill -9` (terminal pane kill) but lacks `kill -TERM` (graceful shutdown request), `kill -HUP` (reconfigure), and `kill -USR1` (user-defined signal).

## Decision

Introduce a **file-based cooperative signal mechanism** using the existing IPC directory. Signals are delivered by creating a file; Workers check for signals at natural phase boundaries.

### Signal delivery

The Orchestrator (or a new `send-signal.sh` script) writes a signal file:

```
/usr/local/var/cekernel/ipc/{SESSION_ID}/
  ├── worker-4              # FIFO (existing: completion notification)
  ├── worker-4.signal       # NEW: signal file
  └── ...
```

Signal file format — a single line of plain text:

```
TERM
```

Supported signals:

| Signal | Meaning | Worker behavior |
|--------|---------|-----------------|
| `TERM` | Graceful shutdown | Finish current atomic unit, commit progress, post status, notify, exit |
| `KILL` | Forced termination | Orchestrator kills terminal pane (existing mechanism via `cleanup-worktree.sh`) |

`KILL` is not written to a file — it is the existing pane-kill behavior, listed here for completeness. The signal file mechanism covers only cooperative signals that require Worker participation.

### Signal checking (Worker side)

Workers check for signals at **phase boundaries** — the natural pause points between atomic units of work:

```
Phase 0 (Plan)
  ← CHECK SIGNAL
Phase 1 (Implement)
  ← CHECK SIGNAL (between TDD cycles)
Phase 2 (Create PR)
  ← CHECK SIGNAL
Phase 3 (CI verify + merge)
  ← CHECK SIGNAL (between CI poll iterations)
Phase 4 (Notify)
```

The check is a single file existence test:

```bash
SIGNAL_FILE="${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.signal"
if [[ -f "$SIGNAL_FILE" ]]; then
  SIGNAL=$(cat "$SIGNAL_FILE")
  rm -f "$SIGNAL_FILE"        # consume the signal
  # handle based on signal type
fi
```

On receiving `TERM`, the Worker:

1. Commits any uncommitted work to the branch (preserves progress)
2. Posts a status comment on the issue: "Worker cancelled by signal. Progress committed to branch `issue/N-slug`."
3. Calls `notify-complete.sh <issue> cancelled "TERM signal received"`
4. Exits

### New script: `send-signal.sh`

```bash
send-signal.sh <issue-number> <signal>
# Example: send-signal.sh 4 TERM
```

Writes the signal file to the IPC directory. Returns immediately (asynchronous delivery). The Orchestrator or user can call this.

### UNIX Philosophy Alignment

> Rule of Modularity: "Write simple parts connected by clean interfaces."

The signal mechanism is a single new script (`send-signal.sh`) and a file-existence check in the Worker. It does not modify existing scripts — `notify-complete.sh`, `watch-worker.sh`, and `health-check.sh` continue to work unchanged. The signal is a new, independent module that plugs into the existing IPC directory.

> Rule of Composition: "Design programs to be connected with other programs."

Signal files are plain text. A human can create one with `echo TERM > worker-4.signal`. A cron job can signal Workers. A future scheduler can signal Workers. The mechanism requires no special client — anything that can write a file can send a signal.

> Rule of Transparency: "Design for visibility to make inspection and debugging easier."

Signal files are visible in the filesystem. `ls /usr/local/var/cekernel/ipc/{SESSION_ID}/` immediately shows which Workers have pending signals. The signal is not hidden in a pipe buffer or process memory — it sits on disk until consumed, inspectable at any time.

> Rule of Repair: "When you must fail, fail noisily and as soon as possible."

When a Worker receives `TERM`, it posts a status comment on the issue explaining what happened, commits progress, and reports `cancelled` status through the FIFO. The cancellation is visible to both the Orchestrator (via FIFO) and humans (via issue comment). Silent disappearance is eliminated.

## Alternatives Considered

### Alternative: Bidirectional FIFO

Add a reverse FIFO (`worker-4.reverse`) for Orchestrator→Worker messages. Worker reads it in non-blocking mode at checkpoints.

Rejected:

> Rule of Simplicity: "Design for simplicity; add complexity only where you must."

A reverse FIFO introduces complexity disproportionate to the need. Non-blocking reads from FIFOs in bash require `read -t 0` or file descriptor juggling. FIFOs have writer/reader lifecycle constraints (blocking on open if no reader). Signal files have none of these issues — `[[ -f ... ]]` is the simplest possible check. A signal is a discrete event, not a stream; a file is a better representation than a pipe.

### Alternative: Unix process signals (kill -TERM)

Send actual POSIX signals to the Claude Code process running in the Worker pane. Requires tracking the Worker's PID.

Rejected:

> Rule of Separation: "Separate policy from mechanism; separate interfaces from engines."

cekernel spawns Workers by sending a command to a terminal pane. It does not own or manage the resulting process tree. The Claude Code process may spawn subprocesses (language servers, test runners, etc.) whose PIDs are unknown to cekernel. Sending `SIGTERM` to the top-level process does not guarantee graceful agent-level shutdown — it terminates the process, but the agent has no opportunity to commit progress or post status. Process signals operate at the wrong abstraction layer; cekernel needs agent-level signals, not process-level signals.

### Alternative: Extend the existing FIFO to be bidirectional

Repurpose the existing `worker-N` FIFO for both directions: Worker writes completion messages, Orchestrator writes signals.

Rejected:

FIFOs are unidirectional by design. Using a single FIFO for bidirectional communication introduces race conditions: both ends must coordinate who reads and who writes at any given moment. The current usage (Worker writes once at completion, Orchestrator reads once) is clean precisely because it's unidirectional. Adding signals to the same pipe would require a protocol layer to distinguish signal messages from completion messages — unnecessary complexity when a simple file achieves the same result.

## Consequences

### Positive

- Workers can be gracefully stopped, preserving uncommitted work on the branch
- Enables future preemption (#77): Orchestrator sends `TERM` to low-priority Worker, waits for acknowledgment, spawns high-priority Worker in the freed slot
- `send-signal.sh` is composable: can be called by Orchestrator, by cron (#79), by the user directly, or by other scripts
- Existing mechanisms unchanged: `notify-complete.sh`, `watch-worker.sh`, `health-check.sh`, `cleanup-worktree.sh` all continue to work as-is
- `KILL` (pane termination) remains available as the last resort when cooperative shutdown fails

### Negative

- Cooperative, not preemptive: a Worker that ignores signal checks (bug or infinite loop in Claude agent) will never respond to `TERM`. The `KILL` fallback (pane termination) is still necessary for this case
- Signal checking adds latency: a Worker in the middle of Phase 1 implementation will not see the signal until the next phase boundary. In the worst case, this could be minutes of continued work after the signal is sent
- Worker agent definition (`worker.md`) gains complexity: signal checking logic must be described at each phase boundary

### Trade-offs

**Simplicity vs. Responsiveness**: File-based signals are checked at phase boundaries, not continuously. A Worker deep in implementation may take minutes to notice a `TERM`. More responsive options (reverse FIFO with polling, process signals) were rejected for their complexity. The trade-off is acceptable because cekernel's use cases (issue direction change, priority shift, end-of-day shutdown) are not time-critical — minutes of latency before graceful shutdown is far better than immediate kill with lost work.

**Cooperative vs. Preemptive**: The mechanism depends on Worker cooperation. A misbehaving Worker can ignore signals indefinitely. This mirrors Unix's own model: `SIGTERM` is cooperative (process can catch and handle it), `SIGKILL` is preemptive (kernel forces termination). cekernel retains both options: `TERM` signal file for cooperative shutdown, pane kill for forced termination.

## Review Notes

### Improvement option: Background signal watcher for finer-grained detection

During review, we investigated whether a Worker could detect signals faster than phase-boundary checking by using Claude Code's background task mechanism.

**Approach**: On startup, the Worker spawns a background Bash task (`run_in_background: true`) that polls for the signal file:

```bash
# Background watcher (spawned by Worker at startup)
while [[ ! -f "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.signal" ]]; do
  sleep 5
done
cat "${CEKERNEL_IPC_DIR}/worker-${ISSUE_NUMBER}.signal"
```

When the signal file appears, the background task completes. Claude Code injects the completion notification into the Worker's conversation at the next **turn boundary** — which occurs between every API round-trip (every few tool calls), far more frequently than phase boundaries.

| Detection method | Granularity | Latency |
|-----------------|-------------|---------|
| Phase-boundary check (ADR base) | Between phases | Minutes |
| Background watcher (this option) | Between turns | Seconds to tens of seconds |

**Platform constraints identified**:

- Claude Code is fundamentally a synchronous, turn-based agent. There is no mechanism for true mid-turn interruption ([anthropics/claude-code#3455](https://github.com/anthropics/claude-code/issues/3455)).
- Background task completion notifications are queued until the next turn boundary — cooperative, not preemptive.
- Known reliability issues with background task notifications ([#21048](https://github.com/anthropics/claude-code/issues/21048), [#20525](https://github.com/anthropics/claude-code/issues/20525)).
- The Worker still needs to correctly interpret the notification and initiate graceful shutdown, which depends on prompt design in `worker.md`.

**Recommendation**: This is a viable improvement over phase-boundary checking, but should not replace it. Phase-boundary checks remain the reliable baseline; background watching is an additive optimization. The signal file mechanism (delivery side) is unchanged — only the detection strategy differs.
