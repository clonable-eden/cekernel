# Glimmer

アイデアの火種を温める場所。並列エージェントワークフローの実験プロジェクト。

## Marketplace

このリポジトリは Claude Code プラグインマーケットプレイスを兼ねている。

```bash
/plugin marketplace add clonable-eden/glimmer
/plugin install kernel@clonable-eden-glimmer
```

## Plugins

- **kernel** — 並列エージェント基盤。`/kernel:orchestrate` スキルと orchestrator/worker エージェントを提供。開発時は `kernel/CLAUDE.md` を読むこと。

## Conventions

- ブランチ名: `issue/{number}-{short-description}`
- commit message の title は英語、body は日本語 OK
- PR の body に `closes #{issue-number}` を含める
- worktree は `.worktrees/` 配下に作成（.gitignore 済み）
