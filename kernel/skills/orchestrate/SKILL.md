---
description: Issue並列処理ワークフローを開始する
allowed-tools: Bash
---

# /orchestrate

指定された issue を git worktree + WezTerm ウィンドウで並列処理するワークフローを管理する。

## Usage

ユーザーから issue 番号（単数または複数）を受け取り、Orchestrator として振る舞う。
詳細なプロトコルは `${CLAUDE_PLUGIN_ROOT}/agents/orchestrator.md` を参照。

## Workflow

### Step 1: Issue 確認

```bash
gh issue view <number>
```

issue の内容を確認し、以下を判断:
- 要件が明確か（AI-ready か）
- 依存関係があるか
- base branch は main でよいか

不明点があればユーザーに確認する。

### Step 2: Worker 起動

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh <issue-number> [base-branch]
```

ユーザーに起動する issue 番号と base branch を確認してから実行する。
複数 issue の場合は順次 spawn する。

### Step 3: 並列監視

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/watch-workers.sh <issue-numbers...>
```

全 Worker の完了を待機する。完了・失敗の結果をユーザーに報告する。

### Step 4: クリーンアップ

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh <issue-number>
```

merge が完了した worktree を削除する。

## Notes

- 複数 issue を同時に処理する場合、依存関係のチェックを先に行う
- Worker 起動前に必ずユーザーの確認を取る
- エラー発生時はユーザーにエスカレーションする
- 各 orchestrate セッションは固有の `SESSION_ID` を持ち、IPC パスが分離される。
  同一マシンで複数セッションを並行実行しても FIFO が衝突しない。
