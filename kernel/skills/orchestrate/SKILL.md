---
description: Issue の優先度判断後、Orchestrator エージェントに委譲して並列処理する
allowed-tools: Bash, Read, Task(kernel:orchestrator)
---

# /orchestrate

指定された issue を Orchestrator エージェントに委譲し、git worktree + WezTerm ウィンドウで並列処理する。

## Usage

ユーザーから issue 番号（単数または複数）を受け取る。

## Workflow

### Step 1: Issue のトリアージと優先度判断

各 issue の内容を `gh issue view` で確認し、以下を検証する:

1. **要件の明確さ**: 何を変更すべきか具体的に記述されているか
2. **スコープ**: 実装範囲が特定できるか

要件が曖昧または不十分な issue がある場合は、ユーザーに報告して対応を確認する（issue の修正、スキップ、続行など）。

複数 issue の場合はさらに:

3. issue 間の依存関係を分析（A の完了が B の前提になるか）
4. 依存関係がある場合はフェーズ分けし、実行順序をユーザーに提示して確認を取る

### Step 2: Orchestrator エージェント起動

Task tool で `kernel:orchestrator` サブエージェントを起動する:

- `subagent_type`: `kernel:orchestrator`
- `prompt`: issue 番号、base branch（指定があれば）、実行順序（Step 1 で決定した場合）を含める

Orchestrator が自律的に以下を実行する:

1. issue 確認・トリアージ（曖昧な issue は FAIL）
2. Worker 起動
3. 完了監視
4. クリーンアップ

### Step 3: 結果報告

Orchestrator の結果をユーザーに報告する。
