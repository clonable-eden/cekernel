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
| `waitpid` | `watch-workers.sh` |
| zombie reaping | `cleanup-worktree.sh` |
| PID | issue number |

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
    spawn-worker.sh          # worktree作成 + WezTermウィンドウ起動
    notify-complete.sh       # Worker → Orchestrator 完了通知
    watch-workers.sh         # 複数Workerの完了を並列監視
    cleanup-worktree.sh      # worktree + branch 削除
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

## IPC: Named Pipe

Worker 間通信には `/tmp/glimmer-ipc/worker-{issue}` の FIFO を使用。
daemon 不要、カーネルレベル IPC、`select`/`poll` 対応。
