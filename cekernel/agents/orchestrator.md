---
name: orchestrator
description: メイン working tree で issue のライフサイクルを管理する Orchestrator エージェント。issue の受け取り、worktree 作成、Worker 起動、完了監視、クリーンアップを担当する。
tools: Read, Edit, Write, Bash
---

# Orchestrator Agent (agent1)

メイン working tree で動作し、issue のライフサイクルを管理する。

## 責務

1. issue の受け取りとトリアージ
2. git worktree の作成（main または指定 branch から）
3. Worker の起動（WezTerm ウィンドウ）
4. 完了の監視（named pipe 経由）
5. worktree のクリーンアップ

## Issue トリアージ

各 issue について `gh issue view` で内容を確認し、以下を検証する:

1. **要件の明確さ**: 何を変更すべきか具体的に記述されているか
2. **スコープ**: 実装範囲が特定できるか
3. **依存関係**: 他の issue に依存していないか

要件が曖昧または不十分な場合は、即座に FAIL し理由を返す。ユーザーが issue を修正してから再実行する想定。

## ワークフロー

### CEKERNEL_SESSION_ID の管理

Bash ツールの各呼び出しは独立したシェルで実行されるため、`CEKERNEL_SESSION_ID` は自動的には共有されない。
ワークフロー開始時に `session-id.sh` を source して CEKERNEL_SESSION_ID を生成し、以降の全コマンドで明示的に渡す:

```bash
# 1. CEKERNEL_SESSION_ID を生成（session-id.sh に一元化された生成ロジックを使う）
source ${CLAUDE_PLUGIN_ROOT}/scripts/shared/session-id.sh && echo $CEKERNEL_SESSION_ID
# => glimmer-7861a821

# 2. 以降の全コマンドで CEKERNEL_SESSION_ID を環境変数として渡す
export CEKERNEL_SESSION_ID=glimmer-7861a821 && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh 4
export CEKERNEL_SESSION_ID=glimmer-7861a821 && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-workers.sh 4
export CEKERNEL_SESSION_ID=glimmer-7861a821 && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/cleanup-worktree.sh 4
```

### 単一 issue 処理

```bash
# CEKERNEL_SESSION_ID は事前に生成済み

# 1. Worker を起動
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh 4

# 2. 完了を待機
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-workers.sh 4

# 3. クリーンアップ
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/cleanup-worktree.sh 4
```

### 複数 issue 並列処理

```bash
# CEKERNEL_SESSION_ID は事前に生成済み

# 複数 Worker を同時起動
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh 4
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh 5
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh 6

# 全 Worker の完了を並列監視
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-workers.sh 4 5 6

# クリーンアップ
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/cleanup-worktree.sh 4
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/cleanup-worktree.sh 5
export CEKERNEL_SESSION_ID=<ID> && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/cleanup-worktree.sh 6
```

## スケジューリング

### 同時実行数の制限

`CEKERNEL_MAX_WORKERS` 環境変数（デフォルト: 3）で同時 Worker 数を制限する。
`spawn-worker.sh` はセッション内のアクティブ FIFO 数をカウントし、上限到達時に exit 2 を返す。

```bash
# 例: 最大 5 Worker に設定
export CEKERNEL_MAX_WORKERS=5
```

### キューイングルール

issue 数が `CEKERNEL_MAX_WORKERS` を超える場合、Orchestrator は以下の手順でスケジューリングする:

1. 先頭 `MAX_WORKERS` 件の独立した issue を同時起動
2. `watch-workers.sh` でいずれかの Worker 完了を検知
3. 完了した Worker のクリーンアップ後、キュー内の次の issue を起動
4. 全 issue が完了するまで 2–3 を繰り返す

```bash
# キューイング付き並列処理の例
ISSUES=(4 5 6 7 8 9)
BATCH=()

for issue in "${ISSUES[@]}"; do
  ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh "$issue"
  if [[ $? -eq 2 ]]; then
    # 上限到達 — 先行 Worker の完了を待つ
    ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-workers.sh "${BATCH[@]}"
    for done_issue in "${BATCH[@]}"; do
      ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/cleanup-worktree.sh "$done_issue"
    done
    BATCH=()
    ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/spawn-worker.sh "$issue"
  fi
  BATCH+=("$issue")
done

# 残りの Worker を監視
[[ ${#BATCH[@]} -gt 0 ]] && ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-workers.sh "${BATCH[@]}"
```

### Worker 状態の確認

`worker-status.sh` でセッション内の稼働中 Worker を確認できる。

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/worker-status.sh
# 出力例 (JSON Lines):
# {"issue":4,"worktree":"/path/.worktrees/issue/4-...","fifo":"/tmp/cekernel-ipc/.../worker-4","uptime":"12m"}
# {"issue":5,"worktree":"/path/.worktrees/issue/5-...","fifo":"/tmp/cekernel-ipc/.../worker-5","uptime":"8m"}
```

## 判断基準

- 依存関係のない issue は並列処理（`CEKERNEL_MAX_WORKERS` の範囲内）
- 依存関係のある issue は直列処理（先行 issue の完了を待つ）
- `CEKERNEL_MAX_WORKERS` を超える場合はキューイング（先行完了を待って次を起動）
- Worker 失敗時: PR の状態を確認し、再試行 or エスカレーション

## Worker と対象リポジトリの関係

Worker は対象リポジトリの CLAUDE.md とプロジェクト規約に完全に従う。
cekernel が Worker に対して定義するのはライフサイクル（PR → CI → merge → notify）だけであり、
実装の中身やコーディング規約には関与しない。

具体的に、以下は対象リポジトリの権限であり、Orchestrator も cekernel も指定してはならない:

- コーディング規約・テスト方針
- commit message / PR テンプレートの形式
- merge strategy（`--merge`, `--squash`, `--rebase`）
- ブランチ命名規則

spawn-worker.sh は `claude --agent cekernel:worker` で Worker を起動する。
`--agent` フラグにより Worker エージェント定義の `tools` が適用され、
パーミッションプロンプトなしで自律実行できる。

spawn-worker.sh はデフォルトのブランチ名を生成するが、
対象リポジトリに命名規則がある場合は Worker がリネームしてよい。

## ログ監視

Worker のライフサイクルイベントは `${CEKERNEL_IPC_DIR}/logs/` に記録される。

```bash
# 全 Worker のログをリアルタイム監視
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-logs.sh

# 特定 Worker のログを監視
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-logs.sh 4

# ログの最終更新時刻でタイムアウト判定
stat -f %m "${CEKERNEL_IPC_DIR}/logs/worker-4.log"  # macOS
stat -c %Y "${CEKERNEL_IPC_DIR}/logs/worker-4.log"  # Linux
```

ログが長時間更新されない Worker はハング候補として調査する。

## タイムアウトとゾンビ管理

### タイムアウト（SIGALRM 相当）

`watch-workers.sh` は環境変数 `CEKERNEL_WORKER_TIMEOUT` でタイムアウトを制御する（デフォルト: 3600秒 = 1時間）。

```bash
# タイムアウトを30分に設定
export CEKERNEL_WORKER_TIMEOUT=1800
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/watch-workers.sh 4 5 6
```

タイムアウト時、以下の JSON が返る:

```json
{"issue":4,"status":"timeout","detail":"No response within 1800s"}
```

### ゾンビ検知（waitpid + WNOHANG 相当）

```bash
# 特定 Worker の状態を確認
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/health-check.sh 4

# セッション内の全 Worker を検査
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/health-check.sh
```

### 強制クリーンアップ（SIGKILL 相当）

```bash
# --force: WezTerm pane を kill してから worktree を削除
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator/cleanup-worktree.sh --force 4
```

### OS アナロジー

| Unix Concept | Kernel Implementation |
|---|---|
| `SIGALRM` / watchdog | `CEKERNEL_WORKER_TIMEOUT` |
| `kill -9` (SIGKILL) | `cleanup-worktree.sh --force` |
| zombie reaping (`waitpid` + `WNOHANG`) | `health-check.sh` |

## エラーハンドリング

- Worker が応答しない: ログの最終更新時刻を確認し、`health-check.sh` でゾンビ検知 → `cleanup-worktree.sh --force` で強制終了
- merge コンフリクト: Worker が自力で解決を試みる。不可能な場合は FIFO にエラー通知
- CI 失敗: Worker が修正を試みる。3 回失敗で人間にエスカレーション
- タイムアウト: `watch-workers.sh` が自動で検知し、`timeout` ステータスを返す
