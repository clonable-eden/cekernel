---
description: kernel プラグインのバージョンをリリースする
allowed-tools: Read, Bash(git *), Bash(gh *)
---

# /release-kernel

kernel プラグインのリリーススキル。git log を分析して semver bump レベルを推奨し、ユーザー確認後に CI をトリガーする。

## Workflow

### Step 1: 現在のバージョンを取得

`kernel/.claude-plugin/plugin.json` から現在のバージョンを読み取る。

### Step 2: 最新リリースタグを特定

```bash
git tag -l 'kernel-v*' --sort=-v:refname | head -1
```

タグが存在しない場合は全履歴を対象とする。

### Step 3: 変更ログを取得

```bash
# タグが存在する場合
git log <last-tag>..HEAD --oneline -- kernel/

# タグが存在しない場合
git log --oneline -- kernel/
```

### Step 4: bump レベルを判定

セマンティックバージョニングルールに従い、変更内容を分析して bump レベルを判定する:

| Bump | 条件 | 例 |
|------|------|----|
| **patch** | バグ修正、ドキュメント更新、テスト追加 | `fix:`, `docs:`, `test:`, `refactor:` |
| **minor** | 新スクリプト/スキル追加、後方互換な機能拡張 | `feat:` |
| **major** | 破壊的変更: 引数変更、環境変数廃止、スクリプト削除 | 既存の呼び出し元が壊れる変更 |

conventional commits の prefix を参考にしつつ、コミット内容も考慮して判定する。
複数の変更がある場合は最も大きい bump レベルを採用する。

### Step 5: ユーザーに確認

以下の情報をユーザーに提示する:

- 現在のバージョン
- 変更ログ（コミット一覧）
- 推奨 bump レベルとその理由
- 新バージョン

ユーザーの確認を得てから次に進む。ユーザーが別の bump レベルを指定した場合はそれに従う。

### Step 6: CI をトリガー

```bash
gh workflow run kernel-release.yml -f version=<new-version> -f plugin=kernel
```

### Step 7: 結果を確認

ワークフローの実行状況を確認し、結果をユーザーに報告する:

```bash
gh run list --workflow=kernel-release.yml --limit=1
```
