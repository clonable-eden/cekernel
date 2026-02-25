#!/usr/bin/env bash
# test-rollback.sh — spawn-worker.sh のロールバック関数テスト
#
# spawn-worker.sh 全体は WezTerm 依存のため直接実行できない。
# ここでは rollback() 関数のロジックを抽出してテストする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

KERNEL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "test: rollback"

# テスト用セッション
export SESSION_ID="test-rollback-00000001"
source "${KERNEL_DIR}/scripts/session-id.sh"
source "${KERNEL_DIR}/scripts/claude-json-helper.sh"

# ── テスト用の一時 Git リポジトリを作成 ──
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

FAKE_REPO="${TEST_TMP}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" commit --allow-empty -m "initial" --quiet

# テスト用の ~/.claude.json
FAKE_CLAUDE_JSON="${TEST_TMP}/claude.json"
export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"

# ── rollback 関数を spawn-worker.sh から抽出して再定義 ──
# wezterm はモック化（CI で使えないため）
wezterm() { return 0; }
export -f wezterm

# rollback 関数を source する（spawn-worker.sh と同じロジック）
# spawn-worker.sh に定義される rollback() を直接テストするため、
# ここでは同じ変数名・ロジックでテストする。
source_rollback() {
  # spawn-worker.sh から rollback 関数だけを抽出
  # これは spawn-worker.sh の rollback() と同一であることを前提とする
  local script="${KERNEL_DIR}/scripts/spawn-worker.sh"
  # rollback 関数を抽出して eval する
  local func_body
  func_body=$(sed -n '/^rollback()/,/^}/p' "$script")
  if [[ -z "$func_body" ]]; then
    echo "  FAIL: rollback() function not found in spawn-worker.sh" >&2
    return 1
  fi
  eval "$func_body"
}

# ── セットアップ: クリーンな状態を保証 ──
rm -rf "$SESSION_IPC_DIR"
mkdir -p "$SESSION_IPC_DIR"

# ── Test 1: 全リソースが存在する状態でロールバック → すべてクリーンアップされる ──
(
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"

  # git コマンドが正しいリポジトリで動作するように cd
  cd "$FAKE_REPO"

  # リソース作成
  ISSUE_NUMBER="100"
  WORKTREE_DIR="${FAKE_REPO}/.worktrees"
  BRANCH="issue/100-test-rollback"
  WORKTREE="${WORKTREE_DIR}/${BRANCH}"

  mkdir -p "$WORKTREE_DIR"
  git worktree add -b "$BRANCH" "$WORKTREE" HEAD --quiet

  FIFO="${SESSION_IPC_DIR}/worker-${ISSUE_NUMBER}"
  mkfifo "$FIFO"

  LOG_DIR="${SESSION_IPC_DIR}/logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/worker-${ISSUE_NUMBER}.log"
  echo "test log" > "$LOG_FILE"

  echo "fake-pane-id" > "${SESSION_IPC_DIR}/pane-${ISSUE_NUMBER}"

  # trust 登録
  register_trust "$WORKTREE"

  # ロールバック関数を取得・実行
  source_rollback
  rollback 2>/dev/null

  # 検証
  assert_not_exists "FIFO removed after rollback" "$FIFO"
  assert_not_exists "Pane file removed after rollback" "${SESSION_IPC_DIR}/pane-${ISSUE_NUMBER}"
  assert_not_exists "Worktree removed after rollback" "$WORKTREE"
  assert_not_exists "Log file removed after rollback" "$LOG_FILE"

  # trust が解除されていることを確認
  if [[ -f "$CLAUDE_JSON" ]]; then
    TRUST=$(jq -r ".projects[\"${WORKTREE}\"] // \"null\"" "$CLAUDE_JSON")
    assert_eq "Trust unregistered after rollback" "null" "$TRUST"
  else
    echo "  PASS: Trust unregistered after rollback (file removed)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi

  # ブランチが削除されていることを確認
  if git -C "$FAKE_REPO" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    echo "  FAIL: Branch still exists after rollback"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo "  PASS: Branch deleted after rollback"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi

  report_results
)

# ── Test 2: 部分的なリソース（FIFO のみ）でロールバック → エラーなし ──
rm -rf "$SESSION_IPC_DIR"
mkdir -p "$SESSION_IPC_DIR"
rm -f "$FAKE_CLAUDE_JSON"

(
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"

  # FIFO のみ作成（worktree、pane 未作成）
  ISSUE_NUMBER="101"
  FIFO="${SESSION_IPC_DIR}/worker-${ISSUE_NUMBER}"
  mkfifo "$FIFO"

  # WORKTREE, BRANCH, MAIN_PANE は未定義のまま

  source_rollback
  rollback 2>/dev/null

  assert_not_exists "FIFO removed in partial rollback" "$FIFO"

  report_results
)

# ── Test 3: リソースが何もない状態でロールバック → エラーなし ──
rm -rf "$SESSION_IPC_DIR"
mkdir -p "$SESSION_IPC_DIR"

(
  export CLAUDE_JSON="$FAKE_CLAUDE_JSON"
  export LOCK_DIR="${FAKE_CLAUDE_JSON}.lock"

  ISSUE_NUMBER="102"
  # 何も作成しない

  source_rollback
  rollback 2>/dev/null
  RESULT=$?

  assert_eq "Rollback with no resources exits cleanly" "0" "$RESULT"

  report_results
)

# ── クリーンアップ ──
rm -rf "$SESSION_IPC_DIR"
