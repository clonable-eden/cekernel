# ADR-0019: Worker Lifecycle Stop Hook Guard via additionalContext

## Status

Accepted

## Context

Claude Code v2.1.166 (2026-06-06) added `hookSpecificOutput.additionalContext`
to `Stop` / `SubagentStop` hook output: the hook's string is delivered as
**non-error feedback** and the conversation continues so Claude can act on it.
Unlike `decision: "block"`, it is rendered as hook feedback rather than a hook
error. Both paths share the same loop protections (`stop_hook_active` input
field, hard cap of 8 consecutive continuations per stop). Verified against the
official hooks documentation on 2026-07-07; the platform facts are recorded in
[claude-code-constraints.md](../claude-code-constraints.md#hooks).

Issue #533 listed three candidate uses for cekernel:

1. **Reviewer checkpoint-warning suppression** (PR #520 territory)
2. **Worker turn continuation** — keep the Worker session going from PR
   creation into CI verification instead of relying solely on prompt
   instructions and watch.sh recovery paths
3. **Orchestrator completion-condition loops** (`/goal`-style "continue until
   no open issues")

Two constraints shape where such hooks can live:

- **Separation of Authority**: cekernel manages only the lifecycle of its own
  agents; implementation conventions belong to the target repository. A hook
  that expresses cekernel-origin Worker/Reviewer behavior is lifecycle
  machinery, not a target-repo convention.
- **`--bare` spawns skip hook auto-discovery** (headless docs): hooks in the
  target repository's `.claude/settings.json` or the user's `~/.claude` never
  load in cekernel's bare-mode Worker sessions. The documented injection paths
  under `--bare` are explicit flags: `--settings` and `--plugin-dir`. cekernel
  already passes `--plugin-dir <cekernel-root>` on **every** spawn branch
  (bare and non-bare, ADR-0016 Amendment 1), so a plugin-shipped
  `hooks/hooks.json` reaches Worker sessions on both branches.

There is also a live failure mode this can close: a Worker that believes its
turn will be re-invoked (e.g. an auto-detached background wait, #558) ends its
turn before running `notify-complete.sh`, dying silently with its lifecycle
incomplete. Prompt instructions alone cannot prevent a turn from ending; a
`Stop` hook fires exactly at that boundary.

## Decision

### 1. Lifecycle hooks ship in the cekernel plugin (`hooks/hooks.json`)

Hooks that express cekernel-origin lifecycle behavior are cekernel's
authority and are bundled with the plugin. Target-repository hooks remain the
target repository's authority — cekernel does not write hooks into target
repo settings, and target-repo hooks (when not under `--bare`) merge alongside
plugin hooks as normal.

### 2. Adopt candidate 2: Worker Stop guard (`scripts/hooks/worker-stop-guard.sh`)

A plugin `Stop` hook keeps a Worker session running until its lifecycle
completes:

- **Worker detection** reads only the hook's `cwd`: a
  `.cekernel-task.md` with an `issue:` field plus the spawn-written
  `.cekernel-env`. Everything else (interactive sessions, Orchestrators,
  Reviewer subagent worktrees) gets a silent `exit 0`. The guard is
  **fail-open by design** — it must never disturb non-Worker sessions, so
  malformed input also exits silently. `.cekernel-env` is parsed with `sed`,
  never sourced: a hook that runs on every stop must not execute worktree
  content.
- **Stop condition** is the Worker state file: `notify-complete.sh` writes
  `TERMINATED` for every terminal result (ci-passed, failed, cancelled), so
  `TERMINATED` is the single "allowed to stop" state. Any other state
  (including `UNKNOWN` when the state file is missing) returns
  `additionalContext` instructing the Worker to continue the Worker Protocol
  and run `notify-complete.sh` before stopping.
- **Loop safety** relies on the platform protections: the 8-continuation cap
  releases a Worker that genuinely cannot complete. The
  `CEKERNEL_DISABLE_STOP_GUARD=1` kill switch covers humans debugging
  interactively inside a Worker worktree (where the task file and env file
  still exist).
- The hook echoes the input `hook_event_name`, so the same script works
  unchanged if it is ever registered for `SubagentStop`.

### 3. Candidate 1 is obsolete — record, don't implement

The Reviewer checkpoint warning was fixed at its source by PR #520 (spawn.sh
warns only for `AGENT_TYPE == worker`), and ADR-0012 Amendment 2 moved the
Reviewer to an Orchestrator subagent with `isolation: worktree` — the
spawn-based Reviewer path the suppression would have targeted no longer
exists. Injecting `additionalContext` to mask a warning would have treated the
symptom; the mechanism remains available (e.g. `SubagentStart` context
injection with a `^cekernel:reviewer$` matcher) if a real Reviewer-context
need appears.

### 4. Candidate 3 is deferred

Orchestrator completion-condition loops overlap with the built-in `/goal`
command (a session-scoped prompt-based Stop hook). Wrapping that in plugin
hook configuration adds mechanism without a demonstrated need (Rule of
Parsimony). Revisit when a concrete Orchestrator long-run requirement exists.

## Consequences

- The "Worker dies before completion notification" failure mode is guarded at
  the turn boundary itself, not just by prompt instructions and watch.sh
  fallback detection. watch.sh's recovery paths stay in place — the hook is an
  additional guard, not a replacement (defense in depth; the state-file
  fallback remains the reliable baseline).
- Plugin hooks fire in **every** session where the plugin is enabled,
  including the operator's interactive sessions. The guard's cwd-based
  detection confines its effect to Worker worktrees; the cost elsewhere is one
  short-lived process per stop.
- Hook output is capped at 10,000 characters and the guard message is far
  below it; multiple hooks returning `additionalContext` for the same event
  all get delivered, so coexistence with target-repo Stop hooks is safe.
- Plugin-hook loading under `--bare --plugin-dir` is documented but not yet
  live-verified in a cekernel spawn; if it turns out not to load, the guard
  silently does not fire and behavior is exactly today's baseline (fail-open).
  Verify during the next long-run and note the result here.
- `plugin.json` needs no change: `hooks/hooks.json` at the plugin root is the
  auto-discovered default location.
