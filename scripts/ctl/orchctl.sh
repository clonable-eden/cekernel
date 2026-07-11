#!/usr/bin/env bash
# orchctl.sh — Worker control interface (systemctl for cekernel)
#
# Usage: orchctl.sh <command> [args...]
#
# Commands:
#   ls                          List all workers across all sessions
#   ps [--session <id>]         List process tree as JSON Lines
#   suspend <target>            Suspend a worker (send SUSPEND signal)
#   resume <target>             Resume a suspended or crashed worker
#   recover <target>            Mark a dead RUNNING worker as crashed
#   term <target>               Send TERM signal (graceful shutdown)
#   kill <target>               Force kill worker
#   nice <target> <priority>    Change worker priority
#   gc [--dry-run]              Clean up stale IPC/lock/worktree resources
#
# Target formats:
#   <issue>                     Match by issue number (unique across all sessions)
#   <repo>:<issue>              Filter by repo name prefix
#   <issue> --session <id>      Explicit session ID
#
# Exit codes:
#   0 — Success
#   1 — Error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/load-env.sh"
source "${SCRIPT_DIR}/../shared/issue-lock.sh"
source "${SCRIPT_DIR}/../shared/worker-state.sh"
source "${SCRIPT_DIR}/../shared/reviewer-state.sh"
source "${SCRIPT_DIR}/../shared/worker-priority.sh"
source "${SCRIPT_DIR}/../shared/claude-bg.sh"
source "${SCRIPT_DIR}/../shared/resolve-repo-root.sh"

CEKERNEL_VAR_DIR="${CEKERNEL_VAR_DIR:-$HOME/.local/var/cekernel}"
IPC_BASE="${CEKERNEL_IPC_BASE:-${CEKERNEL_VAR_DIR}/ipc}"

# ── Usage ──
usage() {
  cat >&2 <<'USAGE'
Usage: orchctl.sh <command> [args...]

Commands:
  ls                          List all workers
  ps [--session <id>]         List process tree as JSON Lines
  suspend <target>            Suspend a worker
  resume <target>             Resume a suspended or crashed worker
  recover <target>            Mark a dead RUNNING worker as crashed
  term <target>               Send TERM signal
  kill <target>               Force kill worker
  nice <target> <priority>    Change priority
  gc [--dry-run]              Clean up stale IPC/lock/worktree resources

Target: <issue> | <repo>:<issue> | <issue> --session <id>
USAGE
  return 1
}

# ── Target resolution ──
# Scans all sessions in IPC_BASE to find a unique worker matching the target.
# Sets: RESOLVED_SESSION, RESOLVED_ISSUE
RESOLVED_SESSION=""
RESOLVED_ISSUE=""

resolve_target() {
  local target="" session_filter=""

  # Parse target and --session flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) session_filter="${2:?--session requires a value}"; shift 2 ;;
      *) target="$1"; shift ;;
    esac
  done

  [[ -n "$target" ]] || { echo "Error: target required" >&2; return 1; }

  local issue repo_prefix
  if [[ "$target" == *:* ]]; then
    repo_prefix="${target%%:*}"
    issue="${target#*:}"
  else
    repo_prefix=""
    issue="$target"
  fi

  # If --session given, use it directly
  # ADR-0020 Phase 1: resolve by state file existence (not FIFO).
  # A state file is written unconditionally at spawn; this makes
  # pipe-less held slots addressable by recover/kill.
  if [[ -n "$session_filter" ]]; then
    local ipc_dir="${IPC_BASE}/${session_filter}"
    if [[ -f "${ipc_dir}/worker-${issue}.state" ]]; then
      RESOLVED_SESSION="$session_filter"
      RESOLVED_ISSUE="$issue"
      return 0
    else
      echo "Error: worker #${issue} not found in session ${session_filter}" >&2
      return 1
    fi
  fi

  # Scan all sessions for matching workers
  local matches=()
  if [[ -d "$IPC_BASE" ]]; then
    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue
      local sid
      sid=$(basename "$session_dir")

      # Apply repo filter: match repo name from metadata file or session ID prefix
      if [[ -n "$repo_prefix" ]]; then
        local sid_repo
        if [[ -f "${session_dir}repo" ]]; then
          sid_repo=$(tr -d '[:space:]' < "${session_dir}repo")
        else
          sid_repo="${sid%-*}"
        fi
        [[ "$sid_repo" == "$repo_prefix" ]] || continue
      fi

      if [[ -f "${session_dir}worker-${issue}.state" ]]; then
        matches+=("${sid}:${issue}")
      fi
    done
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "Error: no worker found for target '${target}'" >&2
    return 1
  elif [[ ${#matches[@]} -gt 1 ]]; then
    echo "Error: ambiguous target '${target}'. Candidates:" >&2
    for m in "${matches[@]}"; do
      echo "  - ${m}" >&2
    done
    return 1
  fi

  RESOLVED_SESSION="${matches[0]%%:*}"
  RESOLVED_ISSUE="${matches[0]#*:}"
  return 0
}

# ── Helper: set IPC context for resolved target ──
set_ipc_context() {
  export CEKERNEL_SESSION_ID="$RESOLVED_SESSION"
  export CEKERNEL_IPC_DIR="${IPC_BASE}/${RESOLVED_SESSION}"
}

# ── Helper: format elapsed seconds as h/m/s ──
format_elapsed() {
  local elapsed="$1"
  if [[ $elapsed -ge 3600 ]]; then
    echo "$((elapsed / 3600))h$((elapsed % 3600 / 60))m"
  elif [[ $elapsed -ge 60 ]]; then
    echo "$((elapsed / 60))m"
  else
    echo "${elapsed}s"
  fi
}

# ── Helper: compute elapsed time from ipc_dir + issue ──
compute_elapsed_from_issue() {
  local ipc_dir="$1" issue="$2"

  # Read process type to locate the right .spawned file
  local process_type="worker"
  local type_file="${ipc_dir}/worker-${issue}.type"
  if [[ -f "$type_file" ]]; then
    process_type=$(tr -d '[:space:]' < "$type_file")
  fi

  # Read spawn epoch from .spawned file (backward compat: empty file falls back to now)
  local spawned_at
  spawned_at=$(cat "${ipc_dir}/${process_type}-${issue}.spawned" 2>/dev/null || true)
  spawned_at="${spawned_at:-$(date +%s)}"

  format_elapsed "$(($(date +%s) - spawned_at))"
}

# ── Helper: detect backend from metadata file (with heuristic fallback) ──
detect_backend() {
  local ipc_dir="$1" issue="$2"

  # Primary: read from metadata file written at spawn time
  local backend_file="${ipc_dir}/worker-${issue}.backend"
  if [[ -f "$backend_file" ]]; then
    tr -d '[:space:]' < "$backend_file"
    return
  fi

  # Fallback: heuristic detection from handle file (pre-#311 workers)
  local handle_file=""
  for hf in "${ipc_dir}"/handle-"${issue}".*; do
    [[ -f "$hf" ]] && handle_file="$hf" && break
  done

  if [[ -z "$handle_file" ]]; then
    echo "unknown"
    return
  fi

  local handle_content
  handle_content=$(tr -d '[:space:]' < "$handle_file")

  if [[ "$handle_content" == *:*.* ]]; then
    echo "tmux"
  elif [[ -f "${ipc_dir}/logs/worker-${issue}.stdout.log" ]]; then
    echo "headless"
  else
    echo "wezterm"
  fi
}

# ══════════════════════════════════════════════
# Commands
# ══════════════════════════════════════════════

# ── ls: List all workers and reviewers across all sessions ──
cmd_ls() {
  local found=0

  if [[ ! -d "$IPC_BASE" ]]; then
    echo "no workers."
    return 0
  fi

  for session_dir in "$IPC_BASE"/*/; do
    [[ -d "$session_dir" ]] || continue
    local sid
    sid=$(basename "$session_dir")
    local sid_repo
    if [[ -f "${session_dir}repo" ]]; then
      sid_repo=$(tr -d '[:space:]' < "${session_dir}repo")
    else
      sid_repo="${sid%-*}"
    fi

    # ADR-0020 Phase 2: enumerate by non-TERMINATED state files, not FIFOs.
    local issue
    for issue in $(worker_state_list_active "$session_dir"); do
      found=$((found + 1))

      # Set context for shared helpers
      export CEKERNEL_IPC_DIR="$session_dir"

      # Type
      local process_type="unknown"
      local type_file="${session_dir}worker-${issue}.type"
      if [[ -f "$type_file" ]]; then
        process_type=$(tr -d '[:space:]' < "$type_file")
      fi

      # State
      local state_json state detail
      state_json=$(worker_state_read "$issue")
      state=$(echo "$state_json" | jq -r '.state')
      detail=$(echo "$state_json" | jq -r '.detail')

      # Priority
      local priority_json priority priority_name
      priority_json=$(worker_priority_read "$issue")
      priority=$(echo "$priority_json" | jq -r '.priority')
      priority_name=$(echo "$priority_json" | jq -r '.priority_name')

      # Elapsed time
      local elapsed
      elapsed=$(compute_elapsed_from_issue "$session_dir" "$issue")

      # Backend
      local backend
      backend=$(detect_backend "$session_dir" "$issue")

      jq -cn \
        --arg session "$sid" \
        --arg repo "$sid_repo" \
        --argjson issue "$issue" \
        --arg type "$process_type" \
        --arg state "$state" \
        --arg detail "$detail" \
        --argjson priority "$priority" \
        --arg priority_name "$priority_name" \
        --arg elapsed "${elapsed:-}" \
        --arg backend "$backend" \
        '{session: $session, repo: $repo, issue: $issue, type: $type, state: $state, detail: $detail, priority: $priority, priority_name: $priority_name, elapsed: $elapsed, backend: $backend}'
    done

    # ADR-0021 Decision 2: enumerate reviewer-*.state separately.
    # Reviewer state is isolated from worker machinery (spawn count,
    # health-check, gc sweep). No priority, backend, or .type file.
    for issue in $(reviewer_state_list_active "$session_dir"); do
      found=$((found + 1))
      export CEKERNEL_IPC_DIR="$session_dir"

      local rstate_json rstate rdetail
      rstate_json=$(reviewer_state_read "$issue")
      rstate=$(echo "$rstate_json" | jq -r '.state')
      rdetail=$(echo "$rstate_json" | jq -r '.detail')

      jq -cn \
        --arg session "$sid" \
        --arg repo "$sid_repo" \
        --argjson issue "$issue" \
        --arg type "reviewer" \
        --arg state "$rstate" \
        --arg detail "$rdetail" \
        --argjson priority "null" \
        --arg priority_name "" \
        --arg elapsed "" \
        --arg backend "subagent" \
        '{session: $session, repo: $repo, issue: $issue, type: $type, state: $state, detail: $detail, priority: $priority, priority_name: $priority_name, elapsed: $elapsed, backend: $backend}'
    done
  done

  if [[ "$found" -eq 0 ]]; then
    echo "no workers."
  fi
}

# ── ps: agents --json view layer (ADR-0016 Phase 4, ADR-0021 #627) ──
# Outputs JSON Lines — one line per orchestrator/worker/reviewer — with a
# `type` field distinguishing process kinds (#660). Schema matches `ls`
# with `type` added. Tree structure assembly is the consumer's
# responsibility (skill / jq).
#
# `claude agents --json` is fetched ONCE per invocation (the body is an
# OPAQUE snapshot — only claude-bg.sh predicates parse it, ADR-0018);
# every registered token (orchestrator.claude-session-id,
# handle-{issue}.{type}) is resolved against that single snapshot. The
# ADR-0018 verdict tokens print as-is so `blocked` (permission-dialog
# stall) is surfaced distinctly; an absent token shows as `not-listed`,
# schema drift as `unknown-value` — a view reports honestly, it does not
# interpret. Worker rows (handle-based) join cekernel-specific columns —
# issue, phase (state-file detail), priority — per the ADR-0015 boundary.
# Reviewer rows come from reviewer-*.state files (subagents have no
# session token — ADR-0021 Decision 2). Sessions without an orchestrator
# token (interactive orchestrators) still list their workers.
cmd_ps() {
  local session_filter=""

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) session_filter="${2:?--session requires a value}"; shift 2 ;;
      *) echo "Error: unknown option '$1'" >&2; return 1 ;;
    esac
  done

  local found=0

  if [[ ! -d "$IPC_BASE" ]]; then
    echo "no orchestrators."
    return 0
  fi

  # Single fetch — the whole command is a view over this one response
  local agents_json
  agents_json=$(claude_bg_agents_json) || agents_json="[]"

  for session_dir in "$IPC_BASE"/*/; do
    [[ -d "$session_dir" ]] || continue
    local sid
    sid=$(basename "$session_dir")

    # Apply --session filter
    if [[ -n "$session_filter" && "$sid" != "$session_filter" ]]; then
      continue
    fi

    # ── Orchestrator row ──
    local sid_file="${session_dir}orchestrator.claude-session-id"
    if [[ -f "$sid_file" ]]; then
      local token
      token=$(tr -d '[:space:]' < "$sid_file")
      if [[ -n "$token" ]]; then
        # Compute elapsed from orchestrator.spawned
        local elapsed=""
        local spawned_file="${session_dir}orchestrator.spawned"
        if [[ -f "$spawned_file" ]]; then
          local spawned_at
          spawned_at=$(tr -d '[:space:]' < "$spawned_file")
          spawned_at="${spawned_at:-$(date +%s)}"
          elapsed=$(format_elapsed "$(($(date +%s) - spawned_at))")
        fi

        local verdict
        verdict=$(claude_bg_token_verdict_from_json "$agents_json" "$token") || true

        found=$((found + 1))
        jq -cn \
          --arg session "$sid" \
          --arg type "orchestrator" \
          --arg claude "$token" \
          --arg elapsed "${elapsed:-}" \
          --arg verdict "$verdict" \
          '{session: $session, type: $type, claude: $claude, elapsed: $elapsed, verdict: $verdict}'
      fi
    fi

    # ── Managed rows: Worker sessions (handle-based, ADR-0016 Phase 4) ──
    for handle_file in "${session_dir}"handle-*.*; do
      [[ -f "$handle_file" ]] || continue
      local fname issue_type issue mtype
      fname=$(basename "$handle_file")
      issue_type="${fname#handle-}"
      issue="${issue_type%%.*}"
      mtype="${issue_type#*.}"
      [[ "$issue" =~ ^[0-9]+$ ]] || continue

      local mtoken
      mtoken=$(tr -d '[:space:]' < "$handle_file")
      [[ -n "$mtoken" ]] || continue

      local mverdict
      mverdict=$(claude_bg_token_verdict_from_json "$agents_json" "$mtoken") || true

      # Join cekernel-specific columns from state/priority files.
      # CEKERNEL_IPC_DIR is scoped to each command substitution (subshell)
      # — a read-only view must not mutate the global session context.
      local phase priority
      phase=$(CEKERNEL_IPC_DIR="$session_dir" worker_state_read "$issue" | jq -r '.detail')
      priority=$(CEKERNEL_IPC_DIR="$session_dir" worker_priority_read "$issue" | jq -r '.priority')

      found=$((found + 1))
      jq -cn \
        --arg session "$sid" \
        --arg type "$mtype" \
        --argjson issue "$issue" \
        --arg claude "$mtoken" \
        --arg phase "$phase" \
        --argjson priority "$priority" \
        --arg verdict "$mverdict" \
        '{session: $session, type: $type, issue: $issue, claude: $claude, phase: $phase, priority: $priority, verdict: $verdict}'
    done

    # ── Managed rows: Reviewer subagents (state-file based, ADR-0021 #627) ──
    # Reviewers run as Orchestrator subagents — no handle, no session token.
    # Their state is surfaced from reviewer-<issue>.state files.
    for rissue in $(reviewer_state_list_active "$session_dir"); do
      local rstate_json rstate rdetail
      rstate_json=$(CEKERNEL_IPC_DIR="$session_dir" reviewer_state_read "$rissue")
      rstate=$(echo "$rstate_json" | jq -r '.state')
      rdetail=$(echo "$rstate_json" | jq -r '.detail')

      found=$((found + 1))
      jq -cn \
        --arg session "$sid" \
        --arg type "reviewer" \
        --argjson issue "$rissue" \
        --arg state "$rstate" \
        --arg detail "$rdetail" \
        '{session: $session, type: $type, issue: $issue, state: $state, detail: $detail}'
    done
  done

  if [[ "$found" -eq 0 ]]; then
    echo "no orchestrators."
  fi
}

# ── suspend: Send SUSPEND signal ──
cmd_suspend() {
  resolve_target "$@" || return 1
  set_ipc_context

  # Check current state
  local state_json state
  state_json=$(worker_state_read "$RESOLVED_ISSUE")
  state=$(echo "$state_json" | jq -r '.state')

  case "$state" in
    RUNNING|WAITING|READY)
      echo "SUSPEND" > "${CEKERNEL_IPC_DIR}/worker-${RESOLVED_ISSUE}.signal"
      echo "Signal SUSPEND sent to worker #${RESOLVED_ISSUE}" >&2
      ;;
    *)
      echo "Error: cannot suspend worker #${RESOLVED_ISSUE} in state ${state}" >&2
      return 1
      ;;
  esac
}

# ── recover: Transition dead RUNNING worker to TERMINATED/crashed ──
cmd_recover() {
  resolve_target "$@" || return 1
  set_ipc_context

  # Check current state — only RUNNING or WAITING can be recovered
  local state_json state
  state_json=$(worker_state_read "$RESOLVED_ISSUE")
  state=$(echo "$state_json" | jq -r '.state')

  case "$state" in
    RUNNING|WAITING) ;;
    *)
      echo "Error: cannot recover worker #${RESOLVED_ISSUE} in state ${state} (must be RUNNING or WAITING)" >&2
      return 1
      ;;
  esac

  # Check if Worker process is alive.
  # Degradation policy (ADR-0018): recover writes TERMINATED/crashed — a
  # destructive verdict — so query-failed / unknown-value must ERROR OUT
  # instead of being coerced to dead (never declare a crash on doubt).
  local backend is_alive=0
  backend=$(detect_backend "$CEKERNEL_IPC_DIR" "$RESOLVED_ISSUE")

  if [[ "$backend" != "unknown" ]]; then
    # Source backend adapter to get backend_worker_status
    export CEKERNEL_BACKEND="$backend"
    source "${SCRIPT_DIR}/../shared/backend-adapter.sh"
    local wverdict
    wverdict=$(backend_worker_status "$RESOLVED_ISSUE" 2>/dev/null) || true
    case "$wverdict" in
      alive|blocked) is_alive=1 ;;
      query-failed|unknown-value)
        echo "Error: cannot verify worker #${RESOLVED_ISSUE} (${wverdict})." \
          "Refusing to mark it crashed — retry when the agents query recovers." >&2
        return 1
        ;;
      *) ;;  # done | stopped | not-listed | missing — verifiably dead
    esac
  fi
  # If backend is "unknown" (no handle, no metadata), worker is dead (is_alive stays 0)

  if [[ "$is_alive" -eq 1 ]]; then
    echo "Error: worker #${RESOLVED_ISSUE} is still alive. Use 'term' or 'kill' instead." >&2
    return 1
  fi

  # Worker is dead — transition state to TERMINATED (crashed)
  worker_state_write "$RESOLVED_ISSUE" TERMINATED "crashed:detected-by-recover"
  echo "Worker #${RESOLVED_ISSUE} recovered: state changed to TERMINATED (crashed:detected-by-recover)." >&2
  echo "Run: orchctl resume ${RESOLVED_ISSUE}" >&2
}

# ── resume: Resume a SUSPENDED or TERMINATED/crashed worker ──
cmd_resume() {
  resolve_target "$@" || return 1
  set_ipc_context

  # Check current state
  local state_json state detail
  state_json=$(worker_state_read "$RESOLVED_ISSUE")
  state=$(echo "$state_json" | jq -r '.state')
  detail=$(echo "$state_json" | jq -r '.detail')

  local can_resume=0
  if [[ "$state" == "SUSPENDED" ]]; then
    can_resume=1
  elif [[ "$state" == "TERMINATED" && "$detail" == crashed* ]]; then
    can_resume=1
  fi

  if [[ "$can_resume" -eq 0 ]]; then
    echo "Error: cannot resume worker #${RESOLVED_ISSUE} in state ${state} (must be SUSPENDED or TERMINATED/crashed)" >&2
    return 1
  fi

  # Change state to READY
  worker_state_write "$RESOLVED_ISSUE" READY "resume-requested"
  echo "Worker #${RESOLVED_ISSUE} state changed to READY (session: ${RESOLVED_SESSION})." >&2
  echo "Run: export CEKERNEL_SESSION_ID=${RESOLVED_SESSION} && spawn-worker.sh --resume ${RESOLVED_ISSUE}" >&2
}

# ── term: Send TERM signal (graceful shutdown) ──
cmd_term() {
  resolve_target "$@" || return 1
  set_ipc_context

  echo "TERM" > "${CEKERNEL_IPC_DIR}/worker-${RESOLVED_ISSUE}.signal"
  echo "Signal TERM sent to worker #${RESOLVED_ISSUE}" >&2
}

# ── kill: Force kill worker ──
cmd_kill() {
  resolve_target "$@" || return 1
  set_ipc_context

  # Detect backend once for all handles
  local backend
  backend=$(detect_backend "$CEKERNEL_IPC_DIR" "$RESOLVED_ISSUE")

  # Stop all sessions for this issue (Worker handles).
  # Reviewer runs as a foreground subagent (no handle since ADR-0021),
  # so only Worker handles are enumerated here.
  # v2: the handle is an opaque session token on ALL backends — the daemon
  # owns the process, so termination delegates to claude stop
  # (ADR-0005 Amendment 1, ADR-0016 Phase 1/5)
  for handle_file in "${CEKERNEL_IPC_DIR}"/handle-"${RESOLVED_ISSUE}".*; do
    [[ -f "$handle_file" ]] || continue
    local handle_content
    handle_content=$(tr -d '[:space:]' < "$handle_file")
    claude_bg_stop "$handle_content"
  done

  # Terminal backends: also close the attach-only visualization pane/window
  # recorded in pane-{issue}.{type} (ADR-0001 Amendment 1)
  for pane_file in "${CEKERNEL_IPC_DIR}"/pane-"${RESOLVED_ISSUE}".*; do
    [[ -f "$pane_file" ]] || continue
    local pane_content
    pane_content=$(tr -d '[:space:]' < "$pane_file")

    case "$backend" in
      tmux)
        local window_target
        window_target=$(echo "$pane_content" | sed 's/\.[0-9]*$//')
        tmux kill-window -t "$window_target" 2>/dev/null || true
        ;;
      headless)
        # No visualization layer — nothing to close
        ;;
      *)
        # wezterm or unknown — try wezterm pane kill
        wezterm cli kill-pane --pane-id "$pane_content" 2>/dev/null || true
        ;;
    esac
    rm -f "$pane_file"
  done

  # ADR-0020 Phase 1: write-once guard — do not overwrite an existing
  # TERMINATED record. An operator killing an already-completed Worker
  # (TERMINATED:ci-passed, review pending) must not relabel the completion,
  # which would strand the issue non-resumable and erase the PR detail.
  # The session stop above stays unconditional (a no-op on a finished session).
  local kill_state_json kill_current_state
  kill_state_json=$(worker_state_read "$RESOLVED_ISSUE")
  kill_current_state=$(echo "$kill_state_json" | jq -r '.state')
  if [[ "$kill_current_state" != "TERMINATED" ]]; then
    worker_state_write "$RESOLVED_ISSUE" TERMINATED "killed"
  fi
  echo "Worker #${RESOLVED_ISSUE} killed." >&2
}

# ── nice: Change worker priority ──
cmd_nice() {
  # Parse: all args except the last are target + flags, last is priority
  local all_args=("$@")

  if [[ ${#all_args[@]} -lt 2 ]]; then
    echo "Error: usage: orchctl.sh nice <target> <priority>" >&2
    return 1
  fi

  # Separate --session and its value from positional args
  local positional=()
  local session_flag=""
  local i=0
  while [[ $i -lt ${#all_args[@]} ]]; do
    if [[ "${all_args[$i]}" == "--session" ]]; then
      session_flag="${all_args[$((i+1))]}"
      i=$((i + 2))
    else
      positional+=("${all_args[$i]}")
      i=$((i + 1))
    fi
  done

  if [[ ${#positional[@]} -lt 2 ]]; then
    echo "Error: usage: orchctl.sh nice <target> <priority>" >&2
    return 1
  fi

  # Last positional arg is priority, first is target
  local last_idx=$((${#positional[@]} - 1))
  local priority="${positional[$last_idx]}"
  local target="${positional[0]}"

  # Rebuild resolve args
  local resolve_args=("$target")
  if [[ -n "$session_flag" ]]; then
    resolve_args+=(--session "$session_flag")
  fi

  resolve_target "${resolve_args[@]}" || return 1
  set_ipc_context

  worker_priority_write "$RESOLVED_ISSUE" "$priority" || return 1

  local updated_json
  updated_json=$(worker_priority_read "$RESOLVED_ISSUE")
  echo "Worker #${RESOLVED_ISSUE} priority updated." >&2
  echo "$updated_json"
}

# ── gc: Clean up stale IPC/lock resources ──
cmd_gc() {
  local dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) echo "Error: unknown option '$1'" >&2; return 1 ;;
    esac
  done

  local cleaned=0
  local locks_dir="${CEKERNEL_VAR_DIR}/locks"

  # Stale timeout for NEW/READY state (seconds). Default: 30 minutes.
  local stale_timeout="${CEKERNEL_GC_STALE_TIMEOUT:-1800}"

  # ── Helper: lazy single `agents --json` fetch per gc run (#573) ──
  # Returns 0 with gc_agents_json populated when the query succeeded;
  # returns 1 when it failed (transient or no CLI) — callers must then
  # stay conservative (assume alive, never gc on doubt).
  local gc_agents_json="" gc_agents_fetched=0 gc_agents_ok=0
  _gc_agents_json_once() {
    if [[ "$gc_agents_fetched" -eq 0 ]]; then
      gc_agents_fetched=1
      if gc_agents_json=$(claude_bg_agents_json); then
        gc_agents_ok=1
      fi
    fi
    [[ "$gc_agents_ok" -eq 1 ]]
  }

  # ── Helper: check if a worker is stale ──
  # Returns 0 (stale) or 1 (active).
  # A worker is stale when:
  #   - State is TERMINATED and no live handle exists
  #   - No handle exists and state is NEW/READY past stale_timeout
  #   - Handle exists but the referenced process is dead
  _gc_is_stale_worker() {
    local sdir="$1" issue="$2" timeout="$3"

    # Check for any handle file
    local has_live_handle=0
    local has_any_handle=0
    for hf in "${sdir}"handle-"${issue}".*; do
      [[ -f "$hf" ]] || continue
      has_any_handle=1
      local handle_content
      handle_content=$(tr -d '[:space:]' < "$hf")
      # v2 (ADR-0016 Phase 5): handle is an opaque session token
      # (UUID/short ID) on ALL backends. Legacy sessions may still hold a
      # tmux pane target (session:window.pane), a numeric wezterm pane ID,
      # or a headless PID.
      # Heuristic: numeric → kill -0; tmux target → has-session; anything
      # else is a session token resolved via the ADR-0018 verdict against
      # a single lazy `agents --json` fetch per gc run (#573).
      # Degradation policy (ADR-0018 — gc refuses to reap on doubt):
      # query-failed and unknown-value both count as ALIVE; only a
      # verifiable done/stopped/not-listed verdict marks the handle dead.
      if [[ "$handle_content" =~ ^[0-9]+$ ]]; then
        if kill -0 "$handle_content" 2>/dev/null; then
          has_live_handle=1
          break
        fi
      elif [[ "$handle_content" == *:*.* ]]; then
        # tmux pane target — check if tmux session exists
        if tmux has-session -t "${handle_content%%:*}" 2>/dev/null; then
          has_live_handle=1
          break
        fi
      else
        # Opaque session token
        if ! _gc_agents_json_once; then
          # Query failed — cannot verify, assume alive
          has_live_handle=1
          break
        fi
        local gc_verdict
        gc_verdict=$(claude_bg_token_verdict_from_json "$gc_agents_json" "$handle_content") || true
        case "$gc_verdict" in
          done|stopped|not-listed) ;;  # verifiably dead
          *)
            has_live_handle=1
            break
            ;;
        esac
      fi
    done

    # If there's a live handle, the worker is active
    if [[ "$has_live_handle" -eq 1 ]]; then
      return 1
    fi

    # Read state from state file
    local state="UNKNOWN"
    local state_file="${sdir}worker-${issue}.state"
    if [[ -f "$state_file" ]]; then
      local line
      line=$(cat "$state_file")
      state="${line%%:*}"
    fi

    # TERMINATED → always stale (process completed)
    if [[ "$state" == "TERMINATED" ]]; then
      return 0
    fi

    # Handle exists but process is dead → stale
    if [[ "$has_any_handle" -eq 1 ]]; then
      return 0
    fi

    # No handle, state is NEW/READY → check timeout via .spawned file
    if [[ "$state" == "NEW" || "$state" == "READY" ]]; then
      # Read process type to locate the right .spawned file
      local gc_type="worker"
      local gc_type_file="${sdir}worker-${issue}.type"
      if [[ -f "$gc_type_file" ]]; then
        gc_type=$(tr -d '[:space:]' < "$gc_type_file")
      fi
      # Read spawn epoch (backward compat: empty file falls back to now)
      local spawned_at
      spawned_at=$(cat "${sdir}${gc_type}-${issue}.spawned" 2>/dev/null || true)
      spawned_at="${spawned_at:-$(date +%s)}"
      local now elapsed
      now=$(date +%s)
      elapsed=$((now - spawned_at))
      if [[ "$elapsed" -ge "$timeout" ]]; then
        return 0
      fi
      # Within timeout — still active
      return 1
    fi

    # No handle, non-terminal state (RUNNING/WAITING/SUSPENDED/UNKNOWN) → stale
    # (A RUNNING worker without any handle is abnormal)
    return 0
  }

  # ── 1. Collect active issues (state files across all sessions) ──
  # Build a set of active issue numbers per session for orphan detection.
  # ADR-0020 Phase 3+4: state files are the sole roster key (FIFOs removed).
  # Non-TERMINATED state files mark the issue active (held slot).
  # Stale workers (non-TERMINATED + dead handle) are reaped here.
  # Uses a temp file instead of declare -A for bash 3.2 compatibility.
  local active_issues_file
  active_issues_file=$(mktemp /tmp/cekernel-gc-active.XXXXXX)

  if [[ -d "$IPC_BASE" ]]; then
    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue

      # Scan state files: non-TERMINATED → check liveness, reap if stale
      for state_file in "$session_dir"worker-*.state; do
        [[ -f "$state_file" ]] || continue
        local sf_name sf_issue sf_state
        sf_name=$(basename "$state_file")
        sf_issue="${sf_name#worker-}"
        sf_issue="${sf_issue%.state}"
        sf_state="UNKNOWN"
        local sf_line
        sf_line=$(cat "$state_file")
        sf_state="${sf_line%%:*}"
        if [[ "$sf_state" != "TERMINATED" ]]; then
          # Check if this non-TERMINATED worker is stale
          if _gc_is_stale_worker "$session_dir" "$sf_issue" "$stale_timeout"; then
            # Stale worker: reap
            if [[ "$dry_run" -eq 1 ]]; then
              echo "[dry-run] would reap stale worker: ${session_dir}worker-${sf_issue}" >&2
            else
              # ADR-0020 Phase 2: write TERMINATED:crashed:detected-by-gc
              # (write-once: never clobber existing TERMINATED).
              local _gc_ts
              _gc_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
              echo "TERMINATED:${_gc_ts}:crashed:detected-by-gc" > "$state_file"
            fi
            # Protect the reaped record from the orphan sweep below
            # (the TERMINATED exit record is the permanent crash evidence).
            echo "${session_dir}:${sf_issue}" >> "$active_issues_file"
            cleaned=$((cleaned + 1))
          else
            echo "${session_dir}:${sf_issue}" >> "$active_issues_file"
          fi
        fi
      done

      # Legacy: remove any stale FIFOs from pre-Phase 3 sessions
      for fifo in "$session_dir"worker-*; do
        [[ -p "$fifo" ]] || continue
        local fname
        fname=$(basename "$fifo")
        [[ "$fname" == worker-* && "$fname" != *.* ]] || continue
        if [[ "$dry_run" -eq 1 ]]; then
          echo "[dry-run] would remove legacy FIFO: $fifo" >&2
        else
          rm -f "$fifo"
        fi
        cleaned=$((cleaned + 1))
      done
    done
  fi

  # ── 2. Clean stale locks ──
  if [[ -d "$locks_dir" ]]; then
    for repo_hash_dir in "$locks_dir"/*/; do
      [[ -d "$repo_hash_dir" ]] || continue
      for lock_dir in "$repo_hash_dir"*.lock; do
        [[ -d "$lock_dir" ]] || continue
        local pid_file="${lock_dir}/pid"
        local is_stale=0

        if [[ -f "$pid_file" ]]; then
          local holder_pid
          holder_pid=$(cat "$pid_file")
          # Delegate to _issue_lock_holder_alive (issue-lock.sh):
          # numeric holders use kill -0, opaque session tokens (v2,
          # ADR-0016) use claude_bg_token_verdict (ADR-0018).
          if ! _issue_lock_holder_alive "$holder_pid"; then
            is_stale=1
          fi
        else
          # No PID file — treat as stale
          is_stale=1
        fi

        if [[ "$is_stale" -eq 1 ]]; then
          if [[ "$dry_run" -eq 1 ]]; then
            echo "[dry-run] would remove stale lock: $lock_dir" >&2
          else
            rm -f "${lock_dir}/pid"
            rmdir "$lock_dir" 2>/dev/null || true
          fi
          cleaned=$((cleaned + 1))
        fi
      done

      # Remove empty repo-hash directory
      if [[ "$dry_run" -eq 0 ]]; then
        rmdir "$repo_hash_dir" 2>/dev/null || true
      else
        # Check if it would be empty after lock removal
        local remaining
        remaining=$(find "$repo_hash_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [[ "$remaining" -eq 0 ]]; then
          echo "[dry-run] would remove empty repo-hash dir: $repo_hash_dir" >&2
        fi
      fi
    done
  fi

  # ── Helper: clean orphan files matching a glob pattern ──
  # Extracts issue number from filename using the given prefix, then checks
  # if the issue is active (has a non-TERMINATED state). If not, removes the file.
  # Args: session_dir glob_pattern prefix label
  _gc_clean_orphan_files() {
    local sdir="$1" pattern="$2" prefix="$3" label="$4"
    for orphan_file in ${sdir}${pattern}; do
      [[ -f "$orphan_file" ]] || continue
      local fname
      fname=$(basename "$orphan_file")
      local issue_with_ext="${fname#"${prefix}"}"
      local issue="${issue_with_ext%%.*}"

      # Skip if there's an active worker
      if grep -qxF "${sdir}:${issue}" "$active_issues_file" 2>/dev/null; then
        continue
      fi

      if [[ "$dry_run" -eq 1 ]]; then
        echo "[dry-run] would remove orphan ${label}: $orphan_file" >&2
      else
        rm -f "$orphan_file"
      fi
      cleaned=$((cleaned + 1))
    done
  }

  # ── 3. Clean stale orchestrator sessions (ADR-0016 Phase 2) ──
  # Liveness is session-ID based via the ADR-0018 verdict: only a
  # verifiable done/stopped/not-listed verdict is dead — query-failed
  # and unknown-value stay conservative (gc refuses to reap on doubt).
  # Dead sessions are reaped via the stop primitive (done sessions
  # linger until explicitly stopped — ADR-0016) and their metadata files
  # removed. Legacy orchestrator.pid files (pre-v2) are swept
  # unconditionally.
  if [[ -d "$IPC_BASE" ]]; then
    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue
      local orch_sid_file="${session_dir}orchestrator.claude-session-id"
      local orch_legacy_pid_file="${session_dir}orchestrator.pid"
      [[ -f "$orch_sid_file" || -f "$orch_legacy_pid_file" ]] || continue

      local orch_token=""
      if [[ -f "$orch_sid_file" ]]; then
        orch_token=$(tr -d '[:space:]' < "$orch_sid_file")
      fi

      # Skip unless the orchestrator session is verifiably dead
      # (done/stopped/not-listed). A legacy pid file without a token is
      # always stale under v2.
      if [[ -n "$orch_token" ]]; then
        local orch_verdict
        orch_verdict=$(claude_bg_token_verdict "$orch_token" 2>/dev/null) || true
        case "$orch_verdict" in
          done|stopped|not-listed) ;;  # verifiably dead — reap below
          *) continue ;;               # alive/blocked or cannot verify
        esac
      fi

      # Orchestrator session is dead — reap it and clean up metadata
      if [[ "$dry_run" -eq 1 ]]; then
        if [[ -n "$orch_token" ]]; then
          echo "[dry-run] would stop dead orchestrator session: $orch_token" >&2
        fi
      else
        claude_bg_stop "$orch_token"
      fi

      for meta_file in "$orch_sid_file" "$orch_legacy_pid_file" \
        "${session_dir}orchestrator.spawned" "${session_dir}repo"; do
        if [[ -f "$meta_file" ]]; then
          if [[ "$dry_run" -eq 1 ]]; then
            echo "[dry-run] would remove stale metadata: $meta_file" >&2
          else
            rm -f "$meta_file"
          fi
          cleaned=$((cleaned + 1))
        fi
      done
    done
  fi

  # ── 4. Clean orphan IPC files (no active worker) ──
  if [[ -d "$IPC_BASE" ]]; then
    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue

      _gc_clean_orphan_files "$session_dir" "worker-*.*"   "worker-"  "IPC file"
      _gc_clean_orphan_files "$session_dir" "handle-*.*"   "handle-"  "handle"
      _gc_clean_orphan_files "$session_dir" "pane-*.*"     "pane-"    "pane"
      _gc_clean_orphan_files "$session_dir" "payload-*.b64" "payload-" "payload"

      # Log files live in a subdirectory.
      # sdir must be session_dir (not session_dir/logs/) so the grep key
      # matches active_issues entries ("session_dir:issue").  (#619 Bug 2)
      if [[ -d "${session_dir}logs" ]]; then
        _gc_clean_orphan_files "${session_dir}" "logs/worker-*" "worker-" "log"

        if [[ "$dry_run" -eq 0 ]]; then
          rmdir "${session_dir}logs" 2>/dev/null || true
        fi
      fi

      # Remove empty session directory
      if [[ "$dry_run" -eq 0 ]]; then
        rmdir "$session_dir" 2>/dev/null || true
      fi
    done
  fi

  # ── Cleanup temp file ──
  rm -f "$active_issues_file"

  # ── 5. Escalation-residue sweep: worktrees + locks vs PR state (#671) ──
  # ADR-0021 Amendment 2 (γ): escalation preserves the worktree and lock
  # for human disposition, and the runbook one-liner is the only reclaim
  # path — if the human merges/closes the PR without executing it, both
  # leak forever. This sweep reclaims them once the PR is verifiably
  # terminal (merged or closed).
  # Degradation policy (ADR-0018 — never reap on doubt): an open PR, a
  # missing PR, a detached HEAD, or a failed gh query all preserve the
  # worktree and lock. Scoped to the repo containing the CWD (worktrees
  # are repo-local); outside a git repo this section is a no-op.
  local sweep_root=""
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    sweep_root=$(resolve_repo_root)
  fi
  if [[ -n "$sweep_root" && -d "${sweep_root}/.worktrees/issue" ]]; then
    local sweep_wt
    for sweep_wt in "${sweep_root}/.worktrees/issue"/*/; do
      [[ -d "$sweep_wt" ]] || continue
      sweep_wt="${sweep_wt%/}"

      # Never sweep the worktree the CWD is inside (CWD safety)
      if [[ "${PWD}/" == "${sweep_wt}/"* ]]; then
        continue
      fi

      local sweep_issue
      sweep_issue=$(basename "$sweep_wt")
      sweep_issue="${sweep_issue%%-*}"
      [[ "$sweep_issue" =~ ^[0-9]+$ ]] || continue

      # Active worker (non-TERMINATED state in ANY session) → keep.
      # Cross-repo issue-number collisions stay conservative: an active
      # worker with this number in any session blocks the sweep.
      local sweep_active=0 sweep_session=""
      if [[ -d "$IPC_BASE" ]]; then
        for session_dir in "$IPC_BASE"/*/; do
          [[ -f "${session_dir}worker-${sweep_issue}.state" ]] || continue
          local sweep_line
          sweep_line=$(cat "${session_dir}worker-${sweep_issue}.state")
          if [[ "${sweep_line%%:*}" != "TERMINATED" ]]; then
            sweep_active=1
            break
          fi
          sweep_session=$(basename "$session_dir")
        done
      fi
      if [[ "$sweep_active" -eq 1 ]]; then
        continue
      fi

      # Branch under review — detached HEAD cannot be matched to a PR
      local sweep_branch
      sweep_branch=$(git -C "$sweep_wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
      [[ -n "$sweep_branch" && "$sweep_branch" != "HEAD" ]] || continue

      # PR state via gh — reclaim only on a verified terminal state:
      # at least one PR for the branch and none of them open.
      local sweep_pr_states
      sweep_pr_states=$(cd "$sweep_root" && gh pr list --head "$sweep_branch" \
        --state all --json state --jq '.[].state' 2>/dev/null) || continue
      [[ -n "$sweep_pr_states" ]] || continue
      if echo "$sweep_pr_states" | grep -qxF "OPEN"; then
        continue
      fi

      if [[ "$dry_run" -eq 1 ]]; then
        echo "[dry-run] would reclaim worktree: $sweep_wt" >&2
        cleaned=$((cleaned + 1))
      else
        # cleanup-worktree.sh owns the removal mechanism (worktree +
        # local branch removal, trust unregistration, IPC cleanup, and
        # the CEKERNEL_KEEP_WORKTREE branch). Pass the session holding
        # the TERMINATED state file so IPC cleanup targets it.
        if CEKERNEL_SESSION_ID="${sweep_session:-${CEKERNEL_SESSION_ID:-}}" \
          "${SCRIPT_DIR}/../orchestrator/cleanup-worktree.sh" "$sweep_issue"; then
          cleaned=$((cleaned + 1))
        else
          echo "gc: cleanup-worktree.sh failed for issue #${sweep_issue} — lock kept" >&2
          continue
        fi
      fi

      # Release the issue lock under the same verified-terminal condition.
      # Escalation holds the lock with an alive/blocked holder, so the
      # holder-liveness sweep (section 2) never frees it.
      local sweep_hash sweep_lock_dir
      sweep_hash=$(issue_lock_repo_hash "$sweep_root")
      sweep_lock_dir="${CEKERNEL_VAR_DIR}/locks/${sweep_hash}/${sweep_issue}.lock"
      if [[ -d "$sweep_lock_dir" ]]; then
        if [[ "$dry_run" -eq 1 ]]; then
          echo "[dry-run] would release lock: $sweep_lock_dir" >&2
        else
          issue_lock_release "$sweep_root" "$sweep_issue"
        fi
        cleaned=$((cleaned + 1))
      fi
    done
  fi

  # ── 6. Summary ──
  if [[ "$cleaned" -eq 0 ]]; then
    echo "gc: nothing to clean." >&2
  else
    if [[ "$dry_run" -eq 1 ]]; then
      echo "gc: ${cleaned} stale resources found (dry-run, nothing cleaned)." >&2
    else
      echo "gc: ${cleaned} stale resources cleaned." >&2
    fi
  fi
}

# ── count: Count running orchestrators (internal, ADR-0014) ──
# Session-ID based (ADR-0016 Phase 2): a session counts on an alive or
# blocked verdict — the vocabulary lives in claude-bg.sh, not here (Rule
# of Separation). Single fetch per invocation (Phase 4): all tokens
# resolve against one opaque snapshot.
# Degradation policy (ADR-0018 — the consumer decides): unknown-value
# counts as alive. For a concurrency guard, over-counting refuses a spawn
# (safe); under-counting spawns a duplicate orchestrator (not safe).
cmd_count() {
  local count=0

  if [[ -d "$IPC_BASE" ]]; then
    local agents_json
    agents_json=$(claude_bg_agents_json) || agents_json="[]"

    for session_dir in "$IPC_BASE"/*/; do
      [[ -d "$session_dir" ]] || continue

      local sid_file="${session_dir}orchestrator.claude-session-id"
      [[ -f "$sid_file" ]] || continue

      local token
      token=$(tr -d '[:space:]' < "$sid_file")
      [[ -n "$token" ]] || continue

      local verdict
      verdict=$(claude_bg_token_verdict_from_json "$agents_json" "$token") || true
      case "$verdict" in
        alive|blocked|unknown-value) count=$((count + 1)) ;;
      esac
    done
  fi

  echo "$count"
}

# ══════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  ls)      cmd_ls "$@" ;;
  ps)      cmd_ps "$@" ;;
  suspend) cmd_suspend "$@" ;;
  resume)  cmd_resume "$@" ;;
  recover) cmd_recover "$@" ;;
  term)    cmd_term "$@" ;;
  kill)    cmd_kill "$@" ;;
  nice)    cmd_nice "$@" ;;
  gc)      cmd_gc "$@" ;;
  count)   cmd_count "$@" ;;
  *)       usage ;;
esac
