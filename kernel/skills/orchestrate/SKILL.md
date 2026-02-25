---
description: Issue並列処理ワークフローを開始する
---

# /orchestrate

指定された issue を Orchestrator エージェントに委譲し、git worktree + WezTerm ウィンドウで並列処理する。

## Usage

ユーザーから issue 番号（単数または複数）を受け取る。

## Workflow

Task tool で `kernel:orchestrator` サブエージェントを起動する:

- `subagent_type`: `kernel:orchestrator`
- `prompt`: issue 番号と base branch（指定があれば）を含める

Orchestrator が自律的に以下を実行する:

1. issue 確認・トリアージ（曖昧な issue は FAIL）
2. Worker 起動
3. 完了監視
4. クリーンアップ

結果が返ってきたらユーザーに報告する。
