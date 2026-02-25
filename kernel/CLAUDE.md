# kernel Development Guide

kernel は Claude Code の並列エージェント基盤。
Unix の概念（プロセス、IPC、スケジューラ）を Claude ワークフローにマッピングしている。
アーキテクチャの詳細は [README.md](./README.md) を参照。

## Architecture

```
kernel/
├── agents/          # エージェント定義 (orchestrator, worker)
├── scripts/
│   ├── orchestrator/  # Orchestrator 用スクリプト
│   ├── worker/        # Worker 用スクリプト
│   └── shared/        # 共有ヘルパー (session-id, claude-json-helper, etc.)
├── skills/          # スキル定義 (/kernel:orchestrate)
└── tests/
    ├── orchestrator/  # Orchestrator スクリプトのテスト
    ├── worker/        # Worker スクリプトのテスト
    └── shared/        # 共有ヘルパーのテスト
```

主要なマッピング:

| Unix | kernel |
|------|--------|
| scheduler | Orchestrator agent |
| process | Worker agent |
| `fork` + `exec` | `spawn-worker.sh` |
| address space | git worktree |
| IPC pipe | named pipe (FIFO) |
| IPC namespace | `SESSION_ID` |

## Scripts

### 基本ルール

すべてのスクリプトは先頭に以下を記述する:

```bash
set -euo pipefail
```

`shared/session-id.sh` を source してセッションスコープを確保する:

```bash
source "${SCRIPT_DIR}/../shared/session-id.sh"
```

### shared/claude-json-helper.sh

`~/.claude.json` の trust エントリを安全に読み書きするヘルパー。`spawn-worker.sh` と `cleanup-worktree.sh` で共有する。

```bash
source "${SCRIPT_DIR}/../shared/claude-json-helper.sh"
register_trust "$WORKTREE"    # worktree パスの trust を登録
unregister_trust "$WORKTREE"  # worktree パスの trust を解除
```

mkdir ベースのファイルロック（`acquire_claude_json_lock` / `release_claude_json_lock`）で並行書き込みを防止する。テスト時は `CLAUDE_JSON` / `LOCK_DIR` 環境変数でパスをオーバーライドできる。

### 既知の罠

`((var++))` は `var=0` のとき exit 1 を返す（bash の算術式で 0 は falsy）。
`set -e` 下では即死するため、代わりに `var=$((var + 1))` を使う:

```bash
# NG: FAILED=0 のとき set -e で死ぬ
((FAILED++))

# OK
FAILED=$((FAILED + 1))
```

### 環境変数

`KERNEL_` プレフィックスを使用する。

デフォルト値には `${VAR:-default}` パターンを使う:

```bash
MAX_WORKERS="${KERNEL_MAX_WORKERS:-3}"
TIMEOUT="${KERNEL_WORKER_TIMEOUT:-3600}"
```

`CLAUDE_PLUGIN_ROOT` はスキル経由の実行時のみ Claude Code が自動設定する。
直接実行にも対応するため `SCRIPT_DIR` からのフォールバックを入れる:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
```

### フラグパース

`while-case` ループで処理する（`cleanup-worktree.sh --force` 参照）:

```bash
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    *) break ;;
  esac
done
```

### Positional 引数のバリデーション

`${1:?Usage: ...}` パターンを使う:

```bash
ISSUE_NUMBER="${1:?Usage: spawn-worker.sh <issue-number> [base-branch]}"
BASE_BRANCH="${2:-main}"
```

## Agents

### Frontmatter

エージェント定義ファイルには以下の frontmatter を記述する:

```yaml
name: <agent-name>
description: <description>
tools: Read, Edit, Write, Bash
```

### 権限の分離

kernel はライフサイクルのみを定義する（spawn → PR → merge → notify）。
実装の規約は対象リポジトリの CLAUDE.md に従う。

Worker の起動プロンプトにも「対象リポジトリの CLAUDE.md を読み、その規約に完全に従う」旨を含める。

ツールの利用可能性は agent frontmatter の `tools` で定義する。ツールの自動承認（パーミッション確認のスキップ）は対象リポジトリの `.claude/settings.json` に完全に委譲する。kernel 側では `--allowedTools` や `permissionMode` を指定しない。Claude Code は worktree 内の `.claude/settings.json` を自動的に読み込むため、リポジトリごとに適切な権限設定が可能になる。スキルファイルでは `allowed-tools` を使用する（エージェントとスキルでキー名が異なる点に注意）。

### Worker Protocol

`worker.md` は以下のフェーズを定義する:

1. **Phase 0** — 対象リポジトリの CLAUDE.md を読む → Execution Plan を issue にコメント投稿
2. **Phase 1** — 実装（コード変更を伴う場合は TDD: RED → GREEN → REFACTOR）
3. **Phase 2** — PR 作成
4. **Phase 3** — CI 確認・merge
5. **Phase 4** — Result を issue にコメント投稿 → `notify-complete.sh` で完了通知

TDD はコード変更を伴う issue では常に実施する。ドキュメントのみの変更等は Worker が判断して省略してよい。

TDD 実施時は commit message に phase suffix を付ける: `(RED)`, `(GREEN)`, `(REFACTOR)`。

## Testing

### テスト対象

**実行可能なスクリプトの振る舞い**のみをテストする。

- OK: `session-id.sh` が `SESSION_ID` を生成・エクスポートする
- OK: `spawn-worker.sh` が同時実行数を超えたとき exit 2 を返す
- NG: `*.md` の内容を grep して特定の文字列が含まれるか確認するだけのテスト

### テストファイル命名

```
tests/
├── run-tests.sh             # テストランナー
├── helpers.sh               # アサーション関数
├── orchestrator/
│   ├── test-concurrency-guard.sh
│   └── test-{feature}.sh   # Orchestrator スクリプトのテスト
├── worker/
│   └── test-{feature}.sh   # Worker スクリプトのテスト
└── shared/
    ├── test-session-id.sh   # session-id.sh のテスト
    └── test-{feature}.sh   # 共有ヘルパーのテスト
```

### アサーション関数

`helpers.sh` が提供する関数を使用する:

```bash
assert_eq <label> <expected> <actual>
assert_match <label> <regex-pattern> <actual>
assert_file_exists <label> <path>
assert_fifo_exists <label> <path>
assert_dir_exists <label> <path>
assert_not_exists <label> <path>
report_results  # "Results: N passed, M failed"
```

### テスト分離

副作用のあるコマンド（WezTerm, `gh`, `git worktree`）はテストから分離するか、モック可能な構造にする。

テストでは専用の `SESSION_ID` を使い、前後でクリーンアップする:

```bash
export SESSION_ID="test-feature-00000001"
source "${KERNEL_DIR}/scripts/shared/session-id.sh"
rm -rf "$SESSION_IPC_DIR"
mkdir -p "$SESSION_IPC_DIR"
# ... tests ...
rm -rf "$SESSION_IPC_DIR"
```

## CI

GitHub Actions が `kernel/**` パス変更時に `run-tests.sh` を実行する。テストが通らない PR は merge しない。

## Versioning

`/plugin update` は `plugin.json` の version 文字列で差分を判断する。
バージョン管理は `/release-kernel` スキルと GitHub Actions で自動化されている。

### セマンティックバージョニングルール

| Bump | 条件 | 例 |
|------|------|----|
| **patch** | バグ修正、ドキュメント更新、テスト追加 | `fix:`, `docs:`, `test:`, `refactor:` |
| **minor** | 新スクリプト/スキル追加、後方互換な機能拡張 | `feat:` |
| **major** | 破壊的変更: 引数変更、環境変数廃止、スクリプト削除 | 既存の呼び出し元が壊れる変更 |

### リリース手順

```bash
/release-kernel
```

スキルが git log を分析し bump レベルを推奨する。確認後 `gh workflow run` で CI をトリガーし、CI が version bump + commit + tag + push を実行する。

### バージョン管理対象

- `kernel/.claude-plugin/plugin.json` — プラグインマニフェスト

### タグ形式

`kernel-v{major}.{minor}.{patch}`（将来の複数プラグイン対応のためプレフィックス付き）

## Conventions

ルートの [CLAUDE.md](../CLAUDE.md) を継承する:

- ブランチ名: `issue/{number}-{short-description}`
- commit message の title は英語、body は日本語 OK
- PR の body に `closes #{issue-number}` を含める

## Self-hosting

kernel 自身の issue も `/kernel:orchestrate` で解決していく。
この CLAUDE.md は Worker が kernel を開発する際のガイドでもある。
