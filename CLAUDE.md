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

## Principles

- Claude Code の仕様や挙動について不確かな場合は、必ず一次情報（公式ドキュメント、GitHub issue）に当たってから回答する。推測で答えない。

## Conventions

- ブランチ名: `issue/{number}-{short-description}`
- commit message の title は英語、body は日本語 OK
- PR の body に `closes #{issue-number}` を含める
- worktree は `.worktrees/` 配下に作成（.gitignore 済み）
- commit message は conventional commits に従う:
  - `feat:` 新機能
  - `fix:` バグ修正
  - `docs:` ドキュメントのみ
  - `test:` テストのみ
  - `refactor:` リファクタリング
  - `release:` バージョンバンプ（CI 自動生成）
