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
| `ulimit -u` (max processes) | `KERNEL_MAX_WORKERS` |
| `ps aux` | `worker-status.sh` |
| process scheduler | Orchestrator のキューイングロジック |
| semaphore | FIFO 数による concurrency guard |

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
    claude-json-helper.sh    # ~/.claude.json trust エントリの読み書きヘルパー
    spawn-worker.sh          # worktree作成 + WezTermウィンドウ起動（concurrency guard 付き）
    worker-status.sh         # 稼働中 Worker の一覧表示
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

### Update

```bash
# 1. マーケットプレイスのリポジトリを最新化
/plugin marketplace update

# 2. プラグインを更新
/plugin update

# 3. Claude Code を再起動して反映
```

> **Note**: `/plugin update` 単体では marketplace のローカルクローンが更新されない場合がある。
> 必ず `/plugin marketplace update` を先に実行すること。

## Usage

```bash
# スキル経由で Orchestrator ワークフローを実行
/kernel:orchestrate

# または直接スクリプトを実行（Orchestrator と同じ手順）

# 1. SESSION_ID を生成
source kernel/scripts/session-id.sh && echo $SESSION_ID
# => glimmer-7861a821

# 2. 各スクリプトを実行（すべて SESSION_ID が必要。シェルが分かれる場合は毎回 export する）
export SESSION_ID=glimmer-7861a821 && kernel/scripts/spawn-worker.sh 4
export SESSION_ID=glimmer-7861a821 && kernel/scripts/worker-status.sh
export SESSION_ID=glimmer-7861a821 && kernel/scripts/watch-workers.sh 4 5 6
export SESSION_ID=glimmer-7861a821 && kernel/scripts/watch-logs.sh
export SESSION_ID=glimmer-7861a821 && kernel/scripts/watch-logs.sh 4
export SESSION_ID=glimmer-7861a821 && kernel/scripts/cleanup-worktree.sh 4

# 同時実行数を変更（デフォルト: 3）
export KERNEL_MAX_WORKERS=5
```

バージョン管理とリリース手順については [kernel/CLAUDE.md の Versioning セクション](./CLAUDE.md#versioning) を参照。

## Worker Permissions

Worker / Orchestrator のエージェント定義には `tools` が設定されており、
以下のツールを使用できる:

| Tool | 用途 |
|------|------|
| `Read` | ファイル読み取り |
| `Edit` | ファイル編集 |
| `Write` | ファイル書き込み |
| `Bash` | git, gh, シェルスクリプト等すべての Bash コマンド |

`spawn-worker.sh` は `claude --agent kernel:worker --allowedTools ...` で Worker を起動する。
`--agent` フラグによりエージェント定義の `tools` が適用され、
`--allowedTools` フラグにより指定ツールがパーミッション確認なしで自動承認される。

なお、エージェントとスキルでは frontmatter のキー名が異なる:
- **エージェント** (`agents/*.md`): `tools`
- **スキル** (`skills/*/SKILL.md`): `allowed-tools`

## TDD Workflow

Worker はコード変更を伴う issue に対して TDD (Red-Green-Refactor) で実装を進める。

```
RED ──→ GREEN ──→ REFACTOR ──→ (次のサイクル or Phase 2)
 │        │          │
 │        │          └─ 重複除去・命名改善・構造整理 → commit
 │        └─ 最小限の実装でテスト通過 → commit
 └─ 失敗するテストを書く → commit
```

ドキュメントのみの変更等、テストが不要な場合は省略される。
詳細は `agents/worker.md` の「開発手法: TDD」セクションを参照。

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

## Resource Governance

### 同時実行数制限

`KERNEL_MAX_WORKERS` 環境変数で同時 Worker 数を制限する（デフォルト: 3）。
`spawn-worker.sh` はセッション内のアクティブ FIFO 数をカウントし、上限に達している場合 exit 2 を返す。
Orchestrator はこの exit code を受けてキューイングを行う。

### Worker Status

`worker-status.sh` でセッション内の稼働中 Worker を JSON Lines 形式で確認できる:

```bash
kernel/scripts/worker-status.sh
# {"issue":4,"worktree":"/path/.worktrees/issue/4-...","fifo":"/tmp/glimmer-ipc/.../worker-4","uptime":"12m"}
```


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
