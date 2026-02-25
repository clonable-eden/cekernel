#!/usr/bin/env bash
# test-spawn-retry.sh — spawn-worker.sh のリトライ時の既存 worktree/branch 処理テスト
#
# リトライ時に前回の失敗で残った stale な worktree/branch を
# クリーンアップしてから再作成できることを検証する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: spawn-retry"

# ── テスト用の一時 Git リポジトリを作成 ──
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

FAKE_REPO="${TEST_TMP}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "initial" --quiet

# ── cleanup_stale_worktree 関数を spawn-worker.sh から抽出 ──
source_cleanup_stale() {
  local script="${KERNEL_DIR}/scripts/orchestrator/spawn-worker.sh"
  local func_body
  func_body=$(sed -n '/^cleanup_stale_worktree()/,/^}/p' "$script")
  if [[ -z "$func_body" ]]; then
    echo "  FAIL: cleanup_stale_worktree() function not found in spawn-worker.sh" >&2
    return 1
  fi
  eval "$func_body"
}

# ── Test 1: stale worktree + branch が存在する状態でクリーンアップ → 再作成成功 ──
echo ""
echo "  Test 1: stale worktree + branch cleanup"
(
  cd "$FAKE_REPO"

  BRANCH="issue/200-stale-retry"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # stale 状態を作成（前回の失敗をシミュレート）
  mkdir -p "$WORKTREE_DIR"
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet

  # worktree と branch が存在することを確認
  assert_dir_exists "Stale worktree exists before cleanup" "$WORKTREE"
  assert_file_exists "Stale worktree has .git file" "${WORKTREE}/.git"

  # cleanup_stale_worktree を実行
  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH"

  # クリーンアップ後に再作成が成功することを検証
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  assert_dir_exists "Worktree recreated after cleanup" "$WORKTREE"

  # 後片付け
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true

  report_results
)

# ── Test 2: stale branch のみ（worktree は rollback 済み）→ 再作成成功 ──
echo ""
echo "  Test 2: stale branch only cleanup"
(
  cd "$FAKE_REPO"

  BRANCH="issue/201-branch-only"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # branch だけ作成（worktree の rollback は成功したが branch 削除が失敗したケース）
  mkdir -p "$WORKTREE_DIR"
  git branch "$BRANCH" HEAD

  # branch が存在することを確認
  git rev-parse --verify "$BRANCH" >/dev/null 2>&1
  assert_eq "Stale branch exists" "0" "$?"

  # cleanup_stale_worktree を実行
  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH"

  # クリーンアップ後に再作成が成功することを検証
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  assert_dir_exists "Worktree created after branch cleanup" "$WORKTREE"

  # 後片付け
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true

  report_results
)

# ── Test 3: 何も残っていない場合 → エラーなしで完了 ──
echo ""
echo "  Test 3: no stale resources"
(
  cd "$FAKE_REPO"

  BRANCH="issue/202-clean-state"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # stale リソースは作成しない
  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH" 2>/dev/null
  RESULT=$?

  assert_eq "No stale resources exits cleanly" "0" "$RESULT"

  report_results
)

# ── Test 4: stale worktree ディレクトリだけ残っている（git worktree list に登録なし）──
echo ""
echo "  Test 4: orphaned worktree directory"
(
  cd "$FAKE_REPO"

  BRANCH="issue/203-orphan-dir"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  # worktree を作成して git worktree remove だけ実行（ディレクトリは残す）
  mkdir -p "$WORKTREE_DIR"
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  git worktree remove --force "$WORKTREE"
  # branch は削除されないので残る
  # ディレクトリも残っている可能性がある（git worktree remove は通常削除するが）
  # 手動でディレクトリを再作成して orphan 状態をシミュレート
  mkdir -p "$WORKTREE"

  source_cleanup_stale
  cleanup_stale_worktree "$WORKTREE" "$BRANCH"

  # orphan ディレクトリが削除され、再作成できることを検証
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet
  assert_dir_exists "Worktree created after orphan cleanup" "$WORKTREE"

  # 後片付け
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true

  report_results
)
