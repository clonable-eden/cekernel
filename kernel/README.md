# kernel

Claude Code の並列エージェント基盤。OS のプロセスモデルに倣い、
issue を独立した Worker に分配・監視・回収する。

## Concept

```
Orchestrator (agent1)              Worker (agent2, 3, 4, ...)
  main working tree                  git worktree per issue
  ┌─────────────┐                  ┌─────────────┐
  │ issue受信    │                  │ issue実装    │
  │ worktree作成 │──spawn──────→   │ テスト       │
  │ FIFO監視     │                  │ PR作成       │
  │   ...waiting │                  │ CI待ち+merge │
  │   ←─signal───│◄─notify─────── │ 完了通知     │
  │ cleanup      │                  └─────────────┘
  └─────────────┘
```

### OS Analogy

| OS | kernel |
|----|--------|
| `init` / scheduler | Orchestrator |
| process | Worker |
| `fork` + `exec` | `spawn-worker.sh` |
| address space | git worktree |
| IPC pipe | named pipe (FIFO) |
| IPC namespace | session (`SESSION_ID`) |
| `waitpid` | `watch-workers.sh` |
| zombie reaping | `cleanup-worktree.sh` |
| PID | issue number |
| `/var/log/` | `${SESSION_IPC_DIR}/logs/` |
| `syslog` | ライフサイクルイベントのログ書き込み |
| `tail -f` / `journalctl` | `watch-logs.sh` |
| log rotation | `cleanup-worktree.sh` でログも削除 |

## Structure

```
kernel/
  .claude-plugin/
    plugin.json              # プラグインマニフェスト
  agents/
    orchestrator.md          # Orchestrator プロトコル定義
    worker.md                # Worker プロトコル定義
  skills/
    orchestrate/
      SKILL.md               # /kernel:orchestrate スキル
  scripts/
    session-id.sh            # セッション ID 生成 + IPC ディレクトリ導出
    spawn-worker.sh          # worktree作成 + WezTermウィンドウ起動
    notify-complete.sh       # Worker → Orchestrator 完了通知
    watch-workers.sh         # 複数Workerの完了を並列監視
    watch-logs.sh            # Workerログのリアルタイム監視
    cleanup-worktree.sh      # worktree + branch + ログ削除
  tests/
    run-tests.sh             # テストランナー
    helpers.sh               # アサーションヘルパー
    test-*.sh                # テストスイート
```

## Install

Claude Code のプラグインマーケットプレイスから導入する:

```bash
# 1. マーケットプレイスを追加
/plugin marketplace add clonable-eden/glimmer

# 2. kernel プラグインをインストール
/plugin install kernel@clonable-eden-glimmer
```

## Usage

```bash
# スキル経由で Orchestrator ワークフローを実行
/kernel:orchestrate

# または直接スクリプトを実行
kernel/scripts/spawn-worker.sh 4        # issue #4 の Worker 起動
kernel/scripts/watch-workers.sh 4 5 6   # 並列監視
kernel/scripts/watch-logs.sh             # 全 Worker のログ監視
kernel/scripts/watch-logs.sh 4           # 特定 Worker のログ監視
kernel/scripts/cleanup-worktree.sh 4    # 後片付け
```

## Constraint: 権限の分離

kernel が定義するのは**ライフサイクル**（spawn → PR → CI → merge → notify → cleanup）だけである。

Worker が実際にコードを書く際は、**対象リポジトリの CLAUDE.md とプロジェクト規約に完全に従う**。
kernel のルールが対象リポジトリの規約と矛盾する場合、対象リポジトリが常に優先する。

```
kernel の権限          対象リポジトリの権限
─────────────          ────────────────────
いつ PR を作るか        どう実装するか
いつ CI を確認するか    コーディング規約
いつ merge するか       テスト方針・lint ルール
いつ通知するか          commit message の形式
                       PR テンプレート
                       merge strategy
                       ブランチ命名規則
                       issue リンク構文
```

対象リポジトリに CLAUDE.md がない場合、Worker は既存のコード・commit・PR から規約を推測する。

## Logging

Worker のライフサイクルイベントはセッションスコープのログディレクトリに記録される。

```
/tmp/glimmer-ipc/{SESSION_ID}/
├── worker-4          # FIFO（既存）
├── worker-7          # FIFO（既存）
└── logs/
    ├── worker-4.log  # Worker #4 のログ
    └── worker-7.log  # Worker #7 のログ
```

### ログフォーマット

```
[2026-02-25T15:30:00Z] SPAWN issue=#4 branch=issue/4-add-feature
[2026-02-25T15:45:00Z] COMPLETE issue=#4 status=merged detail=42
[2026-02-25T15:46:00Z] FAILED issue=#7 status=failed detail=CI failed 3 times
```

### ログ監視

```bash
kernel/scripts/watch-logs.sh             # 全 Worker
kernel/scripts/watch-logs.sh 4           # 特定 Worker
```

### ログのライフサイクル

- **作成**: `spawn-worker.sh` が Worker 起動時に作成
- **書き込み**: `spawn-worker.sh`（SPAWN）、`notify-complete.sh`（COMPLETE/FAILED）
- **削除**: `cleanup-worktree.sh` が worktree クリーンアップ時に削除

## IPC: Named Pipe

Worker 間通信には FIFO（named pipe）を使用。daemon 不要、カーネルレベル IPC、`select`/`poll` 対応。

### セッションスコープ

FIFO パスはセッション単位で名前空間が分離される:

```
/tmp/glimmer-ipc/{SESSION_ID}/worker-{issue}
```

`SESSION_ID` は `session-id.sh` が自動生成する（形式: `{repo-name}-{hex8}`）。
環境変数 `SESSION_ID` が設定済みの場合はそれを使用する。
spawn-worker.sh は WezTerm pane 経由で Worker に `SESSION_ID` を伝播する。

これにより、同一マシンで複数の orchestrate セッションを並行実行しても FIFO が衝突しない。
