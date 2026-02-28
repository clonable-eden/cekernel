# Namespace Detection

> Canonical source for cekernel namespace detection logic.
> See [ADR-0009](../../docs/adr/0009-file-based-namespace-detection.md) for the design decision.

## Detection Snippet

Run the following Bash command to detect whether cekernel is in local or plugin mode:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
if [[ -n "$REPO_ROOT" && -d "${REPO_ROOT}/cekernel/agents" ]]; then
  CEKERNEL_NS="local"
  echo "[NS Detection] mode=local (cekernel source found at ${REPO_ROOT}/cekernel/agents)"
else
  CEKERNEL_NS="plugin"
  echo "[NS Detection] mode=plugin (no cekernel/agents in repo root)"
fi
```

## Agent Name Resolution

Based on the detection result, set agent names:

| Mode | Orchestrator | Worker | Probe |
|------|-------------|--------|-------|
| local | `orchestrator` | `worker` | `probe` |
| plugin | `cekernel:orchestrator` | `cekernel:worker` | `cekernel:probe` |

## Usage from SKILL.md

Each SKILL.md that needs namespace detection should include a step like:

> Read `namespace-detection.md` (this file) and execute the detection Bash snippet via the Bash tool.
> Use the detected mode to set agent names for subsequent steps.

### Path Resolution

This file is located at `cekernel/skills/references/namespace-detection.md` relative to the repository root. To find it:

1. Run `git rev-parse --show-toplevel` to get the repo root
2. Read `${REPO_ROOT}/cekernel/skills/references/namespace-detection.md`

If the file is not found (Read fails), you are in **plugin mode** — use namespaced agent names (`cekernel:orchestrator`, `cekernel:worker`, etc.).
