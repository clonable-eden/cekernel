---
name: probe
description: Diagnostic agent for namespace detection verification. Reports its execution context and runs file-based detection.
tools: Bash, Read
---

# Probe Agent

Diagnostic agent that verifies file-based namespace detection (D2) from the agent's perspective.

## On Startup

Run the following diagnostic and return the results to the caller:

### 1. Execution Context

```bash
echo "[Probe Agent] pwd = $(pwd)"
echo "[Probe Agent] git_toplevel = $(git rev-parse --show-toplevel 2>/dev/null || echo 'NOT A GIT REPO')"
```

### 2. File-based Namespace Detection (D2)

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
if [[ -n "$REPO_ROOT" && -d "${REPO_ROOT}/cekernel/agents" ]]; then
  echo "[Probe Agent] cekernel/agents dir = EXISTS"
  echo "[Probe Agent] namespace = local"
  echo "[Probe Agent] agent_name_would_be = probe"
else
  echo "[Probe Agent] cekernel/agents dir = NOT FOUND"
  echo "[Probe Agent] namespace = cekernel (plugin)"
  echo "[Probe Agent] agent_name_would_be = cekernel:probe"
fi
```

### 3. Script Discovery

Test whether cekernel scripts are discoverable:

```bash
echo "[Probe Agent] which spawn-worker.sh = $(which spawn-worker.sh 2>/dev/null || echo 'NOT IN PATH')"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
if [[ -n "$REPO_ROOT" ]]; then
  echo "[Probe Agent] local spawn-worker.sh = $([[ -f "${REPO_ROOT}/cekernel/scripts/orchestrator/spawn-worker.sh" ]] && echo EXISTS || echo 'NOT FOUND')"
fi
```

## Output

Return all diagnostic output to the caller. Do not take any other actions.
