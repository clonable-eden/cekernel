# ADR-0011: Scheduled Trigger via OS-native Schedulers

## Status

Proposed

## Context

cekernel currently operates in a pull model — a human runs `/dispatch` or `/orchestrate` to trigger issue processing. There is no automated scheduling capability.

In OS terms:

| OS | cekernel |
|----|----------|
| `cron` / `systemd timer` | N/A |
| `at` (one-shot scheduled job) | N/A |

The stabilization of the headless backend (#117, #192) has enabled unattended, terminal-free execution. A three-step verification confirmed feasibility:

1. `claude -p "/dispatch ..."` successfully invokes skills and launches Agents
2. crontab is universally available on macOS, Linux, and WSL
3. Non-interactive environments require explicit `ANTHROPIC_API_KEY` and `.claude/settings.json` permission configuration

### Prerequisites (verified)

| Requirement | Reason |
|-------------|--------|
| `ANTHROPIC_API_KEY` | macOS Keychain is inaccessible in non-interactive environments |
| `.claude/settings.json` (Project Configuration) | Bypasses tool permission prompts |
| PATH resolution | cron environments do not load shell profiles |

## Decision

Introduce two skills that leverage OS-native schedulers. Tier 1 (MVP) uses crontab universally; Tier 2 adds platform-native schedulers.

### Skills

**`cekernel:cron`** — Recurring schedules (analogous to `crontab`)

```
/cron register --label "ready" --schedule "0 9 * * 1-5"
/cron list
/cron cancel [id]
```

**`cekernel:at`** — One-shot scheduled jobs (analogous to `at`)

```
/at register --label "ready" --schedule "2026-03-15T09:00"
/at list
/at cancel [id]
```

### Registry

Schedule metadata is persisted in `~/.claude/cekernel/schedules.json`:

```jsonc
[
  {
    "id": "cekernel-cron-a1b2c3",
    "type": "cron",
    "schedule": "0 9 * * 1-5",
    "label": "ready",
    "repo": "/Users/ryosuke/git/project-alpha",
    "path": "/opt/homebrew/bin:/usr/bin:/bin:...",
    "os_backend": "crontab",
    "os_ref": "cekernel-cron-a1b2c3",
    "created_at": "2026-03-01T10:00:00Z"
  }
]
```

- `register` writes to both the registry and the OS scheduler
- `list` reads the registry file (no OS-side parsing needed)
- `cancel` uses `os_ref` to remove from the OS scheduler, then removes from the registry
- `path` captures the user's `$PATH` at registration time

### Scheduled Command

```bash
PATH=<captured-user-path>
ANTHROPIC_API_KEY=<key>

cd /path/to/repo && claude -p --max-budget-usd 5 --no-session-persistence "/dispatch --env headless --label ready" >> ~/.claude/cekernel/logs/cron.log 2>&1
```

### Tiered Backend

| Platform | Tier 1 (MVP) | Tier 2 |
|----------|-------------|--------|
| macOS | crontab | launchd |
| Linux | crontab | systemd --user |
| Windows (WSL) | crontab | schtasks (native) |

### Preflight Checks

The `register` command validates the following at registration time, aborting on failure:

1. `ANTHROPIC_API_KEY` is set in the environment
2. `which claude`, `which gh`, `which git` all succeed
3. The repository has `.claude/settings.json` with required tools in `allow`
4. `crontab -l` is accessible (OS scheduler is available)

### UNIX Philosophy Alignment

> **Rule of Separation**: "Separate policy from mechanism; separate interfaces from engines."

The **policy** (when and what to run) is defined by Skills (`cron`/`at`), while the **mechanism** (actual schedule registration) is delegated to OS schedulers. cekernel does not implement its own scheduler.

> **Rule of Composition**: "Design programs to be connected with other programs."

The new execution pipeline composes existing components:

```
OS scheduler → claude -p → /dispatch → Orchestrator → Workers
```

Each stage operates independently and is individually testable. `claude -p "/dispatch ..."` is the same command whether invoked manually or from cron.

> **Rule of Representation**: "Fold knowledge into data so program logic can be stupid and robust."

`schedules.json` centralizes schedule metadata, keeping `list` and `cancel` logic simple. The registry absorbs OS scheduler format differences (plist XML, systemd INI, crontab text).

> **Rule of Least Surprise**: "In interface design, always do the least surprising thing."

Skill names (`cron`, `at`) and subcommands (`register`, `list`, `cancel`) follow UNIX command conventions. Users operate with a familiar mental model.

> **Rule of Extensibility**: "Design for the future, because it will be here sooner than you think."

The `os_backend` field enables tracking the transition from crontab to launchd/systemd/schtasks at the registry level. The skill interface (`register`/`list`/`cancel`) remains unchanged.

### Platform Constraints

**Permission Model (Evolving)**: In non-interactive environments, `.claude/settings.json`'s `permissions.allow` is the only mechanism for granting tool permissions. If the target repository lacks this configuration, scheduled execution will fail. The `register` preflight check validates this.

**Authentication**: `claude -p` normally retrieves credentials from the OS Keychain, but cron environments cannot access it. Explicit `ANTHROPIC_API_KEY` is required. This constraint is specific to the Claude Code platform.

## Alternatives Considered

### Alternative: Built-in cekernel scheduler

Implement a scheduling engine within cekernel itself.

Rejected: Violates the Rule of Parsimony ("Write a big program only when it is clear by demonstration that nothing else will do"). Mature schedulers already exist in every OS. Additionally, Claude Code agents are not persistent processes, making a polling-based scheduler infeasible.

### Alternative: GitHub Actions only

Use `.github/workflows/cekernel-cron.yml` for scheduled execution.

Rejected: Repository-scoped, unable to schedule across multiple repositories at the user level. Requires a self-hosted runner, adding setup cost. From the Rule of Diversity perspective, locking into a single execution method is undesirable.

### Alternative: OS-native schedulers from Tier 1

Use launchd/systemd from the start instead of crontab.

Rejected: Following the Rule of Optimization ("Prototype before polishing. Get it working before you optimize it."), validate the MVP with crontab first, then add native support in Tier 2. crontab is universally available on macOS/Linux/WSL, enabling a single code path.

## Consequences

### Positive

- Enables unattended execution: daily triage, periodic maintenance
- Minimal new code by composing existing `/dispatch` skill with OS schedulers
- Reliability and maintainability through delegation to OS schedulers
- Tier 2 adds missed-run catch-up and native log integration

### Negative

- Tier 1 (crontab) lacks missed-run catch-up (skips on sleep/reboot)
- crontab text manipulation is fragile (mitigated in Tier 2)
- `ANTHROPIC_API_KEY` must be stored in plaintext in crontab (security consideration)

### Trade-offs

**Simplicity vs. Robustness**: Tier 1 prioritizes crontab's simplicity over missed-run catch-up. Following the Rule of Optimization, the MVP prioritizes validation. Tier 2 adds launchd/systemd robustness, with the `os_backend` field preserving upgrade paths.

**User-scope vs. Repo-scope**: Placing the registry in `~/.claude/cekernel/` enables user-level scheduling across multiple repositories. Per-repository configuration (e.g., `.cekernel/schedules.json`) is intentionally omitted to maintain simplicity.
