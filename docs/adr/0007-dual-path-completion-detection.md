# ADR-0007: Dual-Path Completion Detection (FIFO + State File Fallback)

## Status

Accepted

## Context

During execution of issue #72, a Worker completed its work successfully — the state file shows `TERMINATED:merged` and the issue was closed. However, `watch-worker.sh`（現 `watch.sh`）remained blocked on FIFO read, and the FIFO (`worker-72`) was absent from the IPC directory. The Orchestrator only detected completion when the 1-hour timeout fired.

Observed IPC directory state:

```
/usr/local/var/cekernel/ipc/cekernel-11535bdc/
  ├── pane-72              # handle file (old naming — see note)
  ├── worker-72.state      # TERMINATED:2026-02-27T09:00:28Z:merged
  ├── worker-72.priority   # exists
  └── (worker-72 FIFO)     # MISSING
```

The handle file is named `pane-72` rather than `handle-72`, suggesting this session straddled the ADR-0005 refactoring. The exact failure point is unknown because no FIFO lifecycle logging exists — we cannot determine whether the FIFO was never created, was deleted prematurely, or whether `notify-complete.sh` failed to find it due to a session ID mismatch.

The root problem is architectural: **the FIFO is a single point of failure for completion detection**, and there is zero observability into its lifecycle. The system already maintains worker state files that redundantly record the same terminal event (TERMINATED), but `watch-worker.sh` ignores them entirely.

### Current flow

```
notify-complete.sh                 watch-worker.sh
─────────────────                  ─────────────────
1. Check FIFO exists → exit 1     1. Check FIFO exists → error JSON
   if missing                        if missing
2. Write state: TERMINATED        2. exec 3<> FIFO (read-write open)
3. echo JSON > FIFO ──────────→   3. read -t TIMEOUT <&3  (BLOCKS)
                                  4. rm FIFO
```

If step 3 on the left never executes (FIFO missing, session ID mismatch, script not called), step 3 on the right blocks for up to `CEKERNEL_WORKER_TIMEOUT` (default 3600s).

## Decision

### 1. Dual-path detection in `watch-worker.sh`

Replace the single blocking `read -t $TIMEOUT` with a poll loop that checks both channels. The initial FIFO existence check no longer returns an immediate error — instead, it falls through to state-file-only polling:

```bash
POLL_INTERVAL="${CEKERNEL_POLL_INTERVAL:-30}"
elapsed=0
local has_fifo=1
local result=""

# If FIFO exists, open it. If not, fall through to state-only polling.
if [[ -p "$fifo" ]]; then
  exec 3<>"$fifo"
else
  has_fifo=0
  echo "Warning: FIFO not found for issue #${issue}. Falling back to state file polling." >&2
fi

while [[ $elapsed -lt $TIMEOUT ]]; do
  # Primary: FIFO read (only if FIFO was available)
  if [[ $has_fifo -eq 1 ]]; then
    if read -r -t "$POLL_INTERVAL" result <&3; then
      exec 3>&-
      rm -f "$fifo"
      break
    fi
  else
    sleep "$POLL_INTERVAL"
  fi

  # Fallback: check state file
  local state_json
  state_json=$(worker_state_read "$issue")
  local state
  state=$(echo "$state_json" | jq -r '.state')
  if [[ "$state" == "TERMINATED" ]]; then
    result=$(build_result_from_state "$state_json")
    echo "Warning: issue #${issue} completed but FIFO notification was not received. Detected via state file." >&2
    [[ $has_fifo -eq 1 ]] && exec 3>&-
    rm -f "$fifo"
    break
  fi

  elapsed=$((elapsed + POLL_INTERVAL))
done

# Timeout: neither FIFO nor state file indicated completion
if [[ -z "$result" ]]; then
  [[ $has_fifo -eq 1 ]] && exec 3>&-
  rm -f "$fifo"
  result="{\"issue\":${issue},\"status\":\"timeout\",\"detail\":\"No response within ${TIMEOUT}s\"}"
  echo "Issue #${issue} timed out after ${TIMEOUT}s." >&2
fi
```

Three detection paths:

| Path | Trigger | Latency |
|------|---------|---------|
| FIFO (primary) | `notify-complete.sh` writes to FIFO | Sub-second |
| State file (fallback) | State file shows TERMINATED, FIFO missed | Up to `POLL_INTERVAL` (30s) |
| Timeout | Neither channel reports completion | `CEKERNEL_WORKER_TIMEOUT` (3600s) |

The FIFO remains the primary fast path. The state file poll at 30-second intervals is a safety net that catches all failure modes — including when the FIFO was never created (the exact scenario from issue #108). One `cat` + `jq` call per 30 seconds per worker.

### 2. State-first ordering in `notify-complete.sh`

Reorder operations so state is always recorded, even if the FIFO write fails:

```
Current:                         Proposed:
1. Check FIFO → exit 1          1. Write state: TERMINATED  (always)
2. Write state: TERMINATED       2. Check FIFO → warn if missing
3. Write to FIFO                 3. Write to FIFO (if available)
```

If the FIFO is missing, log a warning but exit 0 — the state file will be detected by the watcher's fallback. This makes `notify-complete.sh` resilient to FIFO loss without losing the completion signal.

### State file contract for fallback

The state file fallback relies on `worker_state_read` output to reconstruct the completion result. This requires an explicit contract:

**When state is `TERMINATED`, the `detail` field contains the completion status (`merged`, `failed`, or `cancelled`).**

This contract is already upheld by `notify-complete.sh` (`worker_state_write "$ISSUE_NUMBER" TERMINATED "$STATUS"`) but was previously implicit. The fallback helper `build_result_from_state` maps state file fields to the FIFO notification JSON:

```bash
build_result_from_state() {
  local state_json="$1"
  echo "$state_json" | jq -c \
    '{issue: .issue, status: .detail, detail: "detected-via-state-fallback", timestamp: .timestamp}'
}
```

| State file field | Result JSON field | Note |
|-----------------|-------------------|------|
| `.issue` | `.issue` | Direct mapping |
| `.detail` | `.status` | Contract: TERMINATED detail = completion status |
| (literal) | `.detail` | `"detected-via-state-fallback"` marker |
| `.timestamp` | `.timestamp` | Direct mapping |

If `worker_state_write` is called with a TERMINATED detail that is not a completion status (e.g., `"merged:pr-42"`), the fallback result will contain an incorrect `.status`. Implementors modifying state write calls must preserve this contract.

### 3. FIFO lifecycle logging

Add log entries at each stage of the FIFO lifecycle, using the existing per-worker log file (`logs/worker-{issue}.log`):

| Event | Script | Log entry |
|-------|--------|-----------|
| FIFO created | `spawn-worker.sh` | `FIFO_CREATE path=$FIFO` |
| FIFO watch started | `watch-worker.sh` | `FIFO_WATCH_START issue=#N timeout=3600` |
| FIFO notification sent | `notify-complete.sh` | `FIFO_WRITE issue=#N status=merged` |
| FIFO notification received | `watch-worker.sh` | `FIFO_READ issue=#N` |
| FIFO not found (writer) | `notify-complete.sh` | `FIFO_MISSING issue=#N path=$FIFO` |
| State fallback triggered | `watch-worker.sh` | `STATE_FALLBACK issue=#N state=TERMINATED` |

This makes the failure mode from issue #108 immediately diagnosable from the log file alone.

### UNIX Philosophy Alignment

> **Rule of Robustness**: *"Robustness is the child of transparency and simplicity."*

The current design is simple but fragile — a single FIFO failure cascades to a 1-hour timeout. Adding the state file fallback is a minimal complexity increase (one extra check per poll interval) that eliminates an entire class of failure modes. The state file already exists and is already being written; only the reader side is new.

> **Rule of Repair**: *"When you must fail, fail noisily and as soon as possible."*

Currently, FIFO failure is silent — the watcher blocks for up to an hour before the timeout fires. With the state fallback, the mismatch is detected within 30 seconds and logged as a warning. The system self-heals rather than silently degrading.

> **Rule of Transparency**: *"Design for visibility to make inspection and debugging easier."*

The FIFO lifecycle is currently a black box. Adding structured log entries at creation, write, read, and failure points makes the IPC mechanism inspectable. The bug in issue #108 would have been immediately diagnosable.

> **Rule of Composition**: *"Design programs to be connected with other programs."*

The dual-path design composes two existing, independent data channels (FIFO for synchronization, state files for status) into a more robust whole. Neither channel is modified — only the reader learns to consult both.

## Alternatives Considered

### Alternative: Replace FIFO with pure state file polling

Remove FIFOs entirely. `watch-worker.sh` polls state files at regular intervals.

Rejected: Violates Rule of Simplicity. The FIFO provides instant, event-driven notification — replacing it with polling introduces latency (up to `POLL_INTERVAL` seconds) for the common case where everything works. The FIFO is the right primitive for 1:1 synchronization; only its status as **sole** detection channel is the problem.

### Alternative: Heartbeat mechanism

Worker periodically writes a heartbeat file. Watcher detects stale heartbeats and infers failure.

Rejected: Violates Rule of Parsimony. This requires the Worker agent (a Claude AI instance) to periodically run a heartbeat script — difficult to guarantee from within an autonomous agent. The state file already contains a timestamp that serves a similar purpose. Heartbeats also add complexity (cadence configuration, staleness thresholds) without addressing the core issue (FIFO notification lost → completion detected).

### Alternative: Retry FIFO write in `notify-complete.sh`

If FIFO is missing, wait and retry a few times before giving up.

Rejected: Treats the symptom, not the cause. If the FIFO was never created or was deleted, retrying won't help. If it's a timing issue, the state file fallback handles it more reliably. Retry logic also adds unpredictable delays to the Worker's completion path.

## Consequences

### Positive

- Completion detection within 30 seconds even when FIFO notification fails entirely
- Zero-downtime for the happy path — FIFO still provides sub-second notification
- FIFO lifecycle becomes observable via structured log entries
- `notify-complete.sh` becomes resilient — always records state regardless of FIFO availability
- The fix is backwards-compatible: no changes to the FIFO protocol, state file format, or caller interfaces

### Negative

- `watch-worker.sh` gains a dependency on `worker-state.sh` (previously only used by `worker-status.sh`（現 `process-status.sh`）and `spawn-worker.sh`)
- Poll interval adds a theoretical 30-second worst-case latency for the fallback path (acceptable — current worst case is 3600 seconds)
- Slightly more complex `watch_one()` function (loop replaces single `read`)

### Behavioral Changes

**`notify-complete.sh` exit code**: Currently exits 1 when the FIFO is not found. After this change, it exits 0 with a warning log — because the completion signal is still delivered via the state file. The Worker agent protocol (`worker.md`) does not check `notify-complete.sh`'s exit code, and the Worker prompt treats it as a fire-and-forget call. However, any future callers that rely on exit code to determine notification success must be aware of this change.

### Trade-offs

**Simplicity vs. Robustness**: The single blocking `read` is simpler than a poll loop with dual-channel checking. This trade-off is justified — the current simplicity produces a 1-hour failure mode, which is far more costly than the added code complexity. The poll loop is straightforward (no threading, no complex synchronization) and the state file API is already well-tested.

**Consistency of result format**: When the state file fallback triggers, the result JSON uses `detail: "detected-via-state-fallback"` to distinguish it from a genuine FIFO notification. Downstream consumers (orchestrator) see the same structure but can detect which path was taken. This is a transparency aid, not a breaking change.

### Known Issues Out of Scope

**Worker process crash (headless backend)**: This ADR addresses the case where the Worker completes successfully but the FIFO notification is lost. It does not cover the case where the Worker process itself crashes (e.g., OOM kill, signal). In that scenario, `notify-complete.sh` is never called, the state file remains at `RUNNING`, and neither FIFO nor state file fallback can detect completion — the watcher still blocks until timeout.

Terminal backends (WezTerm/tmux) provide passive observability for this case — the operator can see that the terminal pane is dead. Headless mode has no such visibility; only the stdout log file (`logs/worker-{issue}.stdout.log`) and `backend_worker_alive` (which checks `kill -0 $PID`) can detect the crash.

A natural future extension is to add a `backend_worker_alive` check to the poll loop in `watch-worker.sh`: if the state is not TERMINATED and the process is dead, the Worker has crashed. This fits cleanly into the poll loop introduced by this ADR but is a separate concern (crash detection vs. notification loss) and should be addressed independently.
