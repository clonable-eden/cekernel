#!/usr/bin/env bash
# test-worker-permissions.sh — エージェント定義の allowed-tools 検証
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKER_MD="${KERNEL_DIR}/agents/worker.md"
ORCHESTRATOR_MD="${KERNEL_DIR}/agents/orchestrator.md"

echo "test: worker-permissions"

# ── Helper: frontmatter から allowed-tools 行を抽出 ──
extract_allowed_tools() {
  local file="$1"
  # frontmatter (--- ... ---) 内の allowed-tools 行を取得
  sed -n '/^---$/,/^---$/p' "$file" | grep '^allowed-tools:' | sed 's/^allowed-tools: *//' || true
}

# ── Test 1: worker.md に allowed-tools が定義されている ──
WORKER_TOOLS=$(extract_allowed_tools "$WORKER_MD")
assert_eq "worker.md has allowed-tools in frontmatter" "1" "$([[ -n "$WORKER_TOOLS" ]] && echo 1 || echo 0)"

# ── Test 2-7: worker.md に必要なツールが含まれている ──
REQUIRED_TOOLS=("Read" "Edit" "Write" "Bash(git *)" "Bash(gh *)" "Bash(bash *)")
for tool in "${REQUIRED_TOOLS[@]}"; do
  if [[ "$WORKER_TOOLS" == *"$tool"* ]]; then
    assert_eq "worker.md includes ${tool}" "1" "1"
  else
    assert_eq "worker.md includes ${tool}" "present" "missing"
  fi
done

# ── Test 8: orchestrator.md に allowed-tools が定義されている ──
ORCH_TOOLS=$(extract_allowed_tools "$ORCHESTRATOR_MD")
assert_eq "orchestrator.md has allowed-tools in frontmatter" "1" "$([[ -n "$ORCH_TOOLS" ]] && echo 1 || echo 0)"

# ── Test 9-14: orchestrator.md に必要なツールが含まれている ──
for tool in "${REQUIRED_TOOLS[@]}"; do
  if [[ "$ORCH_TOOLS" == *"$tool"* ]]; then
    assert_eq "orchestrator.md includes ${tool}" "1" "1"
  else
    assert_eq "orchestrator.md includes ${tool}" "present" "missing"
  fi
done

# ── Test 15: spawn-worker.sh が --agent kernel:worker を使用している ──
SPAWN_SCRIPT="${KERNEL_DIR}/scripts/spawn-worker.sh"
if grep -q '\-\-agent kernel:worker' "$SPAWN_SCRIPT"; then
  assert_eq "spawn-worker.sh uses --agent kernel:worker" "1" "1"
else
  assert_eq "spawn-worker.sh uses --agent kernel:worker" "present" "missing"
fi

report_results
