# ADR-0009: File-based namespace detection

## Status

Accepted

## Context

cekernel operates in two modes depending on how it is installed:

| Mode | Installation | Agent invocation |
|------|-------------|-----------------|
| Plugin | `/plugin install cekernel@clonable-eden-plugins` | `cekernel:orchestrator`, `cekernel:worker` |
| Local | Project-local `.claude/agents/`, `.claude/skills/` | `orchestrator`, `worker` |

The Orchestrator must know which mode it is running in to spawn Workers with the correct agent name. If a plugin-mode Orchestrator spawns `claude --agent worker`, the agent is not found. If a local-mode Orchestrator spawns `claude --agent cekernel:worker`, it silently uses the outdated plugin-installed version instead of the local development version.

### Current detection: LLM-based (non-deterministic)

The `/orchestrate` skill's Step 0 instructs the LLM to infer the namespace from the `<command-name>` tag:

> Check whether the skill was invoked with a namespace prefix (e.g., `cekernel:orchestrate` vs `orchestrate`).

This approach has a fundamental flaw: the LLM's interpretation of `<command-name>` is **invocation-dependent and non-deterministic**. The same skill can produce different namespace decisions across invocations. Issue #137 documents the consequence: Workers spawned with `cekernel:worker` in a local-mode context, silently using the plugin-installed (outdated) `worker.md` instead of the local development version.

### Self-hosting amplifies the risk

cekernel uses itself for development (`/orchestrate` to resolve its own issues). When the plugin version and local version diverge — which they always do during active development — the wrong namespace means Workers run with an outdated protocol. Changes to `worker.md` (signal handling, state reporting, checkpoint/resume) are silently ignored.

### `CLAUDE_PLUGIN_ROOT` is not a solution

Claude Code provides `${CLAUDE_PLUGIN_ROOT}` for plugin path resolution, but it only works in JSON configuration contexts (hooks, MCP servers). It does **not** expand in SKILL.md or agent markdown files:

| Context | `${CLAUDE_PLUGIN_ROOT}` |
|---------|:-:|
| JSON settings (hooks, MCP servers) | Works |
| SKILL.md | Does not expand |
| Agent markdown | Does not expand |

No string substitution or built-in variable exists to detect namespace from within a skill or agent. Related open issues:

- [anthropics/claude-code#9354](https://github.com/anthropics/claude-code/issues/9354) — `${CLAUDE_PLUGIN_ROOT}` not expanded in command markdown
- [anthropics/claude-code#11011](https://github.com/anthropics/claude-code/issues/11011) — Skill plugin scripts fail path resolution on first run
- [anthropics/claude-code#10113](https://github.com/anthropics/claude-code/issues/10113) — Git-installed plugin skill paths misresolved

## Decision

### 1. File-based namespace detection

Replace LLM-based `<command-name>` interpretation with a deterministic file existence check:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
if [[ -n "$REPO_ROOT" && -f "${REPO_ROOT}/.claude-plugin/plugin.json" ]] && \
   [[ "$(jq -r '.name' "${REPO_ROOT}/.claude-plugin/plugin.json" 2>/dev/null)" == "cekernel" ]]; then
  # Local mode: cekernel source is in this repository
  CEKERNEL_AGENT_ORCHESTRATOR="orchestrator"
  CEKERNEL_AGENT_WORKER="worker"
else
  # Plugin mode: cekernel is installed as a plugin
  CEKERNEL_AGENT_ORCHESTRATOR="cekernel:orchestrator"
  CEKERNEL_AGENT_WORKER="cekernel:worker"
fi
```

The presence of `.claude-plugin/plugin.json` with `"name": "cekernel"` in the repository root is the detection signal. This file exists only in the cekernel source repository (self-hosting). In any other repository using cekernel as a plugin, this file does not exist (or has a different name).

### 2. Self-hosting symlink convention

For file-based detection to work in local mode, Claude Code must be able to resolve non-namespaced agent and skill names. This requires symlinks from `.claude/agents/` and `.claude/skills/` to the cekernel source:

```
.claude/agents/
├── orchestrator.md@ -> ../../agents/orchestrator.md
├── probe.md@        -> ../../agents/probe.md
└── worker.md@       -> ../../agents/worker.md

.claude/skills/
├── orchctrl@       -> ../../skills/orchctrl
├── orchestrate@    -> ../../skills/orchestrate
├── probe@          -> ../../skills/probe
└── unix-architect@ -> ../../skills/unix-architect
```

Without these symlinks, `claude --agent worker` fails because Claude Code cannot find the agent definition. The symlinks make the local definitions discoverable under non-namespaced names.

### 3. Convention: self-hosting uses non-namespaced invocation

In a self-hosting repository (where `.claude-plugin/plugin.json` with name `cekernel` exists), users should invoke skills without the namespace prefix:

- Use `/orchestrate` (not `/cekernel:orchestrate`)
- Use `/probe` (not `/cekernel:probe`)

This aligns the invocation style with the detection result. Using a namespaced invocation in a self-hosting context is a misuse — the user is requesting the plugin version while the local version is available.

### Verification results

The probe skill (`skills/probe/SKILL.md`) and probe agent (`agents/probe.md`) were created to verify D2 file-based detection across 4 scenarios. Each scenario compared LLM-based detection, file-based detection (D2), and agent spawning:

| # | Repository | Invocation | LLM detection | D2 (file) | Agent spawn | Correct answer |
|---|-----------|------------|:---:|:---:|:---:|:---:|
| 1 | cekernel (no symlinks) | `cekernel:probe` | `cekernel` | `local` | `probe` — **failed** | `local` |
| 2 | cekernel (symlinks) | `probe` | `local` | `local` | `probe` — success | `local` |
| 3 | cekernel (symlinks) | `cekernel:probe` | `cekernel` | `local` | `probe` — success | `local`* |
| 4 | dotfiles (external repo) | `cekernel:probe` | `cekernel` | `cekernel` | `cekernel:probe` — success | `cekernel` |

**Key findings:**

- **Scenario 1**: Without symlinks, D2 correctly detects local mode but agent spawn fails loudly (`agent not found`) — this is Rule of Repair in action: the missing symlink causes a noisy failure rather than silently using the wrong (plugin) version
- **Scenario 2**: Full success — D2 detects local, LLM agrees, agent spawns correctly
- **Scenario 3**: D2 detects `local` while LLM detects `cekernel` — D2 is correct because the local source exists and should be used. The namespaced invocation in a self-hosting context is the user error, not a D2 failure
- **Scenario 4**: Both methods agree — external repository correctly resolves to plugin mode

\* Scenario 3: In a self-hosting repository, D2 always returns `local` regardless of invocation namespace. This is the intended behavior — self-hosting means "use the local version". Using `cekernel:probe` in the cekernel repository is an operational error (convention violation, not a detection bug).

D2 achieved **4/4 correct results** under the convention that self-hosting repositories use non-namespaced invocation.

### UNIX Philosophy Alignment

> **Rule of Representation**: *"Fold knowledge into data so program logic can be stupid and robust."*

The namespace decision is encoded in the filesystem (file existence + JSON content) rather than in LLM reasoning. The detection logic is a trivial `if [[ -f ... ]]` + `jq` check — no interpretation, no ambiguity, no variability across invocations. The filesystem is the data; the detection script is stupid and robust.

> **Rule of Transparency**: *"Design for visibility to make inspection and debugging easier."*

The primary differentiator between LLM-based and file-based detection is visibility. LLM reasoning is opaque — when the Orchestrator decides on `cekernel:worker`, there is no inspectable state to verify the decision. File-based detection is immediately visible: `jq .name .claude-plugin/plugin.json` reveals the mode. The detection input (filesystem), logic (`if [[ -f ... ]]` + `jq`), and output (agent name) are all inspectable without special tools.

> **Rule of Robustness**: *"Robustness is the child of transparency and simplicity."*

The transparency above and the simplicity of a single conditional combine to produce robustness. The LLM-based approach fails both halves: it is neither transparent (opaque reasoning) nor simple (depends on `<command-name>` tag parsing behavior that may change).

> **Rule of Least Surprise**: *"In interface design, always do the least surprising thing."*

When a developer is working in the cekernel source repository, they expect `/orchestrate` to use the local `worker.md` — not a plugin-installed copy from a previous release. File-based detection delivers this expectation. The LLM-based approach can surprise by silently using the wrong version.

## Alternatives Considered

### Alternative: LLM-based `<command-name>` detection (current)

The current approach instructs the LLM to check whether the skill was invoked with a namespace prefix and set agent names accordingly.

Rejected:

> Rule of Robustness: *"Robustness is the child of transparency and simplicity."*

The detection depends on the LLM correctly interpreting `<command-name>` tags, which is non-deterministic. Different invocations of the same skill can produce different namespace decisions. Issue #137 demonstrates that this causes Workers to use outdated plugin-version agent definitions, silently corrupting the development workflow. The detection mechanism must be deterministic — it is a correctness requirement, not a preference.

### Alternative: `CLAUDE_PLUGIN_ROOT` string substitution

Use `${CLAUDE_PLUGIN_ROOT}` within SKILL.md or agent markdown to determine plugin vs. local mode.

Rejected:

> Rule of Repair: *"When you must fail, fail noisily and as soon as possible."*

`${CLAUDE_PLUGIN_ROOT}` does not expand in SKILL.md or agent markdown (Claude Code limitation). It silently remains as the literal string `${CLAUDE_PLUGIN_ROOT}`. This violates the Rule of Repair — the failure is silent, not noisy. Until Claude Code resolves this limitation (anthropics/claude-code#9354, #11011, #10113), this approach is not viable.

### Alternative: Environment variable injection via hooks

Use a Claude Code hook (e.g., `PreToolCall`) to detect the plugin context and inject a `CEKERNEL_NAMESPACE` variable.

Not pursued:

Hooks execute in JSON configuration context where `${CLAUDE_PLUGIN_ROOT}` works, so this is technically feasible. However, it adds an invisible dependency on hook configuration — a new user installing the plugin would not have the hook configured. The file-based approach requires no configuration beyond the repository structure itself.

## Consequences

### Positive

- Namespace detection is **deterministic** — same input (filesystem state) always produces the same output
- Self-hosting always uses local definitions — no silent fallback to outdated plugin versions
- Detection is inspectable: `jq .name .claude-plugin/plugin.json` reveals the mode immediately
- No dependency on Claude Code internals (`<command-name>` tag format, `${CLAUDE_PLUGIN_ROOT}` expansion)
- Future-proof: when Claude Code adds proper namespace detection, the inline Bash snippet in each SKILL.md is the only code to update — no mechanism scripts, agent definitions, or hook configurations are involved

### Negative

- Self-hosting requires symlink setup (`.claude/agents/`, `.claude/skills/`) — a one-time manual step
- The convention (non-namespaced invocation in self-hosting) must be communicated to developers
- Plugin-mode repositories that happen to contain a `.claude-plugin/plugin.json` with `"name": "cekernel"` (unlikely but possible) would be misdetected as local mode

### Trade-offs

**Determinism vs. flexibility**: File-based detection always returns `local` in the cekernel source repository, even if the user explicitly invokes `cekernel:orchestrate`. This sacrifices the ability to "force plugin mode in a self-hosting context" — a scenario with no practical use case. The trade-off is strongly in favor of determinism: a detection method that is sometimes wrong is worse than one that is always right for the intended use case.

**Convention vs. automation**: The symlink setup is a manual convention, not an automated process. An `install-self-hosting.sh` script could automate this, but the one-time cost of `ln -s` is low and the explicit setup makes the relationship between `.claude/` and the source directories visible. Automation can be added later without changing the detection mechanism.

## Implementation Scope

This ADR documents the detection **decision** only. The implementation — rewriting `skills/orchestrate/SKILL.md` Step 0 to use Bash-based detection instead of LLM-based `<command-name>` interpretation — is tracked separately.

The detection logic **must** be embedded as inline Bash instructions in each SKILL.md, not extracted to a shared shell script. This is a bootstrap constraint: locating `detect-namespace.sh` requires resolving cekernel's path, which itself requires knowing the namespace — a circular dependency. SKILL.md cannot use `BASH_SOURCE[0]` (not a shell script) or `${CLAUDE_PLUGIN_ROOT}` (not expanded in skill markdown). The probe skill (`skills/probe/SKILL.md`) already demonstrates this inline pattern.

Each skill that needs namespace detection duplicates the ~5 line Bash snippet. This is an acceptable trade-off: the snippet is trivial, stable, and the duplication cost is far lower than the circular dependency it avoids.

## Amendments

### 2026-03-03: Detection signal changed from directory to plugin.json (#207)

The original detection checked for `cekernel/agents/` directory existence. After flattening `cekernel/` to the repository root (#207), this directory no longer exists at that path. The detection signal is now `.claude-plugin/plugin.json` with `"name": "cekernel"`:

**Before**: `if [[ -d "${REPO_ROOT}/cekernel/agents" ]]`
**After**: `if [[ -f "${REPO_ROOT}/.claude-plugin/plugin.json" ]] && [[ "$(jq -r '.name' ...)" == "cekernel" ]]`

This is strictly more precise — it checks both file existence and content, eliminating the (theoretical) false positive from an unrelated `cekernel/agents/` directory. The `jq` dependency already exists (used for `~/.claude.json` manipulation).

The symlink targets are also updated: `../../cekernel/agents/*.md` → `../../agents/*.md` and `../../cekernel/skills/*` → `../../skills/*`.

## References

- Issue: [#137](https://github.com/clonable-eden/cekernel/issues/137) — Namespace resolution bug
- Probe verification: [#137 comment](https://github.com/clonable-eden/cekernel/issues/137) — D2 verification results
- Claude Code limitations: [anthropics/claude-code#9354](https://github.com/anthropics/claude-code/issues/9354), [#11011](https://github.com/anthropics/claude-code/issues/11011), [#10113](https://github.com/anthropics/claude-code/issues/10113), [#12541](https://github.com/anthropics/claude-code/issues/12541)
- ADR-0006 Amendment: `BASH_SOURCE[0]` migration for `CLAUDE_PLUGIN_ROOT` removal
