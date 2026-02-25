---
name: orchestrator
description: メイン working tree で issue のライフサイクルを管理する Orchestrator エージェント。issue の受け取り、worktree 作成、Worker 起動、完了監視、クリーンアップを担当する。
---

# Orchestrator Agent (agent1)

メイン working tree で動作し、issue のライフサイクルを管理する。

## 責務

1. issue の受け取りとトリアージ
2. git worktree の作成（main または指定 branch から）
3. Worker の起動（WezTerm ウィンドウ）
4. 完了の監視（named pipe 経由）
5. worktree のクリーンアップ

## ワークフロー

### 単一 issue 処理

```bash
# SESSION_ID は session-id.sh が自動生成（同一セッション内で共有される）

# 1. Worker を起動（worktree 作成 + ウィンドウ起動）
FIFO=$(${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh 4)

# 2. 完了を待機（ブロッキング）
RESULT=$(cat "$FIFO")

# 3. クリーンアップ
${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh 4
```

### 複数 issue 並列処理

```bash
# 全スクリプトが同一 SESSION_ID を共有（環境変数で自動伝播）

# 複数 Worker を同時起動
${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh 4
${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh 5
${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh 6

# 全 Worker の完了を並列監視
${CLAUDE_PLUGIN_ROOT}/scripts/watch-workers.sh 4 5 6
```

## 判断基準

- 依存関係のない issue は並列処理
- 依存関係のある issue は直列処理（先行 issue の完了を待つ）
- Worker 失敗時: PR の状態を確認し、再試行 or エスカレーション

## Worker と対象リポジトリの関係

Worker は対象リポジトリの CLAUDE.md とプロジェクト規約に完全に従う。
kernel が Worker に対して定義するのはライフサイクル（PR → CI → merge → notify）だけであり、
実装の中身やコーディング規約には関与しない。

具体的に、以下は対象リポジトリの権限であり、Orchestrator も kernel も指定してはならない:

- コーディング規約・テスト方針
- commit message / PR テンプレートの形式
- merge strategy（`--merge`, `--squash`, `--rebase`）
- ブランチ命名規則

spawn-worker.sh はデフォルトのブランチ名を生成するが、
対象リポジトリに命名規則がある場合は Worker がリネームしてよい。

## タイムアウトとゾンビ管理

### タイムアウト（SIGALRM 相当）

`watch-workers.sh` は環境変数 `GLIMMER_WORKER_TIMEOUT` でタイムアウトを制御する（デフォルト: 3600秒 = 1時間）。

```bash
# タイムアウトを30分に設定
export GLIMMER_WORKER_TIMEOUT=1800
${CLAUDE_PLUGIN_ROOT}/scripts/watch-workers.sh 4 5 6
```

タイムアウト時、以下の JSON が返る:

```json
{"issue":4,"status":"timeout","detail":"No response within 1800s"}
```

### ゾンビ検知（waitpid + WNOHANG 相当）

```bash
# 特定 Worker の状態を確認
${CLAUDE_PLUGIN_ROOT}/scripts/health-check.sh 4

# セッション内の全 Worker を検査
${CLAUDE_PLUGIN_ROOT}/scripts/health-check.sh
```

### 強制クリーンアップ（SIGKILL 相当）

```bash
# --force: WezTerm pane を kill してから worktree を削除
${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh --force 4
```

### OS アナロジー

| Unix Concept | Kernel Implementation |
|---|---|
| `SIGALRM` / watchdog | `GLIMMER_WORKER_TIMEOUT` |
| `kill -9` (SIGKILL) | `cleanup-worktree.sh --force` |
| zombie reaping (`waitpid` + `WNOHANG`) | `health-check.sh` |

## エラーハンドリング

- Worker が応答しない: `health-check.sh` でゾンビ検知 → `cleanup-worktree.sh --force` で強制終了
- merge コンフリクト: Worker が自力で解決を試みる。不可能な場合は FIFO にエラー通知
- CI 失敗: Worker が修正を試みる。3 回失敗で人間にエスカレーション
- タイムアウト: `watch-workers.sh` が自動で検知し、`timeout` ステータスを返す
