---
description: "Diagnostic probe for namespace detection. Tests file-based detection (D2) vs LLM-based detection."
argument-hint: ""
allowed-tools: Bash, Read, Task(cekernel:probe), Task(probe)
---

# /probe

Diagnostic skill to verify D2 (file-based namespace detection) from ADR-0009.

## Workflow

### Step 1: LLM-based Detection (Current Method)

Determine whether cekernel is running as a plugin or locally by checking how this skill was invoked.

Check whether the skill was invoked with a namespace prefix (e.g., `cekernel:probe` vs `probe`).

- If namespaced (plugin mode): `LLM_DETECTED_NS=cekernel`
- If not namespaced (local mode): `LLM_DETECTED_NS=local`

Report:

```
[LLM Detection] namespace = <LLM_DETECTED_NS>
[LLM Detection] reason = <how you determined the namespace>
```

### Step 2: File-based Detection (D2 Proposal)

Run the following Bash command to detect namespace via file existence:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
if [[ -n "$REPO_ROOT" && -d "${REPO_ROOT}/cekernel/agents" ]]; then
  FILE_DETECTED_NS="local"
  CEKERNEL_AGENT_PROBE="probe"
else
  FILE_DETECTED_NS="cekernel"
  CEKERNEL_AGENT_PROBE="cekernel:probe"
fi
echo "[File Detection] repo_root = ${REPO_ROOT}"
echo "[File Detection] cekernel/agents exists = $([[ -d "${REPO_ROOT}/cekernel/agents" ]] && echo yes || echo no)"
echo "[File Detection] namespace = ${FILE_DETECTED_NS}"
echo "[File Detection] agent_name = ${CEKERNEL_AGENT_PROBE}"
```

### Step 3: Launch Probe Agent

Using the agent name determined by the **file-based detection** (Step 2), launch the probe agent:

- `subagent_type`: Use `CEKERNEL_AGENT_PROBE` from Step 2
- `prompt`: "Report what you observe. Run the file-based namespace detection from your own context and return the results."

### Step 4: Report

Present a comparison table:

```
## Probe Results

| Method        | Detected Namespace | Agent Name     |
|---------------|-------------------|----------------|
| LLM-based     | <LLM result>      | <agent name>   |
| File-based    | <File result>     | <agent name>   |
| Agent (D2)    | <Agent result>    | <agent name>   |

### Consistency
- LLM vs File: <match/mismatch>
- File vs Agent: <match/mismatch>

### Conclusion
<Whether D2 file-based detection produces correct results in this context>
```
