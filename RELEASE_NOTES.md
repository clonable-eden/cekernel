# cekernel-v1.9.0

## Highlights
- **Orchestrator as independent process**: Orchestrator now runs as a `claude -p --agent` background process via `spawn-orchestrator.sh`, fully decoupled from the dispatch session
- **Reviewer self-review pre-detection**: Reviewer detects self-review before submitting, using `gh api` with `COMMENT` event instead of failing with `gh pr review --approve`
- **Two-tier concurrency model**: `CEKERNEL_MAX_ORCHESTRATORS` limits concurrent Orchestrators at the dispatch level; `CEKERNEL_MAX_ORCH_CHILDREN` (renamed from `MAX_PROCESSES`) limits Workers per Orchestrator. `CEKERNEL_MAX_WORKERS` is deprecated and removed
- **orchctl ps**: New subcommand shows Orchestrator process trees with managed Worker/Reviewer child processes
- **Post-mortem improvements**: Findings now grouped by root-cause class (1-4), Orchestrator transcripts discovered via UUID-based session lookup, exclusion rules prevent false positives
- **CEKERNEL_VAR_DIR portability**: Default changed from `/usr/local/var/cekernel` to `$HOME/.local/var/cekernel` for cross-platform compatibility
- **Testing guardrails**: CLAUDE.md now explicitly prevents content-based tests for non-executable files, with TDD priority clarification

## New Features
- Orchestrator as independent `claude -p` process via `spawn-orchestrator.sh` (#441)
- `orchctl ps` — Orchestrator process tree display with managed process detection (#457, #466)
- `orchctl count` internal subcommand for concurrency checks (#482)
- `orchctl recover` — mark dead RUNNING Workers as crashed (#442)
- `CEKERNEL_MAX_ORCHESTRATORS` concurrency guard in dispatch/orchestrate (#486)
- Rename `CEKERNEL_MAX_PROCESSES` → `CEKERNEL_MAX_ORCH_CHILDREN` (#483)
- `CEKERNEL_VAR_DIR` default changed to `$HOME/.local/var/cekernel` (#506)
- Reviewer self-review pre-detection via `gh api` (#512)
- Review section added to CLAUDE.md for worktree Reviewers (#510)
- `/setup` skill now supports additional variable configuration (#497)
- `desktop-notify.sh` alerter backend for macOS (#427)
- `--yes` flag for `/dispatch` to skip confirmation (#450)
- Triage reads issue comments for fuller context (#449)
- Post-mortem findings grouped by root-cause class (#432)
- UUID-based transcript lookup via `orchestrator.claude-session-id` (#498)
- `orchctl gc` cleans up stale `orchestrator.pid` files (#516)
- `phase-transition.sh` TDD cycle reflected in Worker phase detail (#467)

## Bug Fixes
- Orchestrator PID file not deleted on completion (#474, #516)
- Spawn-reviewer.sh prompt overriding reviewer.md `gh api` instructions (#515)
- Issue lock retained for `changes-requested` and `approved` results (#511)
- Spawn.sh `--resume` skips issue lock re-acquisition (#472)
- Cleanup-worktree.sh missing `.backend`/`.priority` file deletion (#418)
- Orchestrator CWD drift causing spawn-reviewer.sh path duplication (#452)
- Alerter argument format corrected to double-dash (#451)
- WSL toast notification AppId fixed (#436)
- Transcript-locator.sh `--worktrees-` split pattern fixed (#490)
- `claude_session_id_persist` moved to post-Orchestrator startup (#493)
- Test `set -e` resilience for non-zero return functions (#494)
- Checkpoint warning suppressed for normal Reviewer spawns (#520)
- `CEKERNEL_CI_MAX_RETRIES` added to headless.env (#504)
- Env defaults unified across docs, profiles, and scripts (#504)

## Documentation
- ADR-0014: Two-tier concurrency env vars (#478)
- ADR-0008: Env var catalog section (#505)
- CLAUDE.md: Testing guardrails for non-executable files (#518)
- CLAUDE.md: Testing exception for non-executable-only changes (#489)
- Worktree naming convention documented (#420)
- claude-code-constraints.md updated with 2026 knowledge (#417)
- Docs symlinked to `.claude/rules/` for auto-loading (#416)
- Postmortem patterns: checkpoint warning exclusion added (#520)
- Skill reference convention prefix clarified (#455)

## Other Changes
- refactor: `scripts/ctl` directory — `orchctrl` → `orchctl` rename + management scripts separated (#462, #465)
- refactor: stat-based uptime replaced with epoch timestamp in `.spawned` (#434)
- refactor: reviewer.md uses EVENT variable pattern for self-review (#512)
- test: Worker/Reviewer test execution scoped to changed scripts only (#470)

## What's Changed
* Worker agent 定義に TDD コミットルールを直接記載する by @clonable-eden in #398
* feat: add phase-transition.sh to combine signal check and state write by @clonable-eden in #400
* fix: desktop-notify.sh テスト中に実通知が飛ぶ問題を修正 by @clonable-eden in #401
* fix: use cd -P for CEKERNEL_SCRIPTS resolution via symlinks by @clonable-eden in #402
* fix: BASH_SOURCE zsh互換フォールバックでdesktop-notify/issue-lockのno-op問題を修正 by @clonable-eden in #404
* fix: apply BASH_SOURCE[0] zsh fallback to remaining shared scripts by @clonable-eden in #406
* fix: plugin モードで CEKERNEL_SESSION_ID が UUID 形式になる問題を修正 by @clonable-eden in #408
* docs: add Script Invocation section to worker and reviewer agents by @clonable-eden in #410
* release: cekernel v1.8.0 by @clonable-eden in #411
* fix: symlink docs to .claude/rules/ for auto-loading by @clonable-eden in #416
* docs: update claude-code-constraints.md with 2026 knowledge by @clonable-eden in #417
* fix: cleanup-worktree.sh の .backend/.priority 削除漏れを修正 by @clonable-eden in #418
* postmortem: 複数issue対応 + session_id依存排除 by @clonable-eden in #419
* docs: document worktree naming convention by @clonable-eden in #420
* postmortem SKILL.md / CLAUDE.md の細かな修正 by @clonable-eden in #423
* Orchestrator のマージ待ちポーリングによる通知ノイズを修正 by @clonable-eden in #424
* feat: desktop-notify.sh に alerter バックエンドを追加 (macOS) by @clonable-eden in #427
* fix: postmortem SKILL.md — load-env.sh の追加と Orchestrator 識別ロジックの拡張 by @clonable-eden in #429
* docs: reviewer.md に self-review 時の --comment フォールバック手順を追加 by @clonable-eden in #431
* feat: postmortem findings を原因分類でグルーピング by @clonable-eden in #432
* refactor: replace stat-based uptime with epoch timestamp in .spawned file by @clonable-eden in #434
* fix: WSL toast notification AppId を PowerShell 登録済み AppId に変更 by @clonable-eden in #436
* Orchestrator を claude -p 独立プロセスとして起動する by @clonable-eden in #441
* orchctrl recover: dead RUNNING Worker の状態修正コマンド追加 by @clonable-eden in #442
* postmortem: Orchestrator の claude -p 化に伴う transcript 検出パスの更新 by @clonable-eden in #444
* triage: issue のコメントも読み込んで判断する by @clonable-eden in #449
* dispatch: --yes フラグで確認ステップをスキップ可能にする by @clonable-eden in #450
* fix: alerter の引数を double-dash (--) 形式に修正 by @clonable-eden in #451
* fix: Orchestrator CWD drift による spawn-reviewer.sh パス二重化を防止 by @clonable-eden in #452
* Conventions: skill reference ファイルの commit prefix を明確化 by @clonable-eden in #455
* Orchestrator の excessive polling を抑制する by @clonable-eden in #456
* feat: orchctrl ps — Orchestrator プロセスツリーの表示 by @clonable-eden in #457
* fix: correct alerter install command to vjeantet/tap/alerter by @clonable-eden in #458
* scripts/ctl ディレクトリ新設: orchctrl → orchctl リネーム + 管理スクリプト分離 by @clonable-eden in #462
* skills/orchctrl → skills/orchctl にリネーム by @clonable-eden in #465
* orchctl ps: managed プロセス (Worker/Reviewer) をツリーに表示する by @clonable-eden in #466
* Worker の TDD サイクルを phase detail に反映する by @clonable-eden in #467
* Worker/Reviewerのテスト実行を変更対象スクリプトのみに限定する by @clonable-eden in #470
* fix: spawn.sh --resume 時に issue lock の再取得をスキップ by @clonable-eden in #472
* fix: alerter環境でtest-desktop-notify-zsh-compatが失敗する問題を修正 by @clonable-eden in #473
* Orchestrator 完了時に orchestrator.pid を削除する by @clonable-eden in #474
* docs: fix post-refactoring documentation inconsistencies by @clonable-eden in #476
* docs: add ADR-0014 for two-tier concurrency env vars by @clonable-eden in #478
* feat: add orchctl count internal subcommand by @clonable-eden in #482
* feat: rename CEKERNEL_MAX_PROCESSES → CEKERNEL_MAX_ORCH_CHILDREN by @clonable-eden in #483
* docs: ADR-0006の旧変数名参照を更新 (MAX_WORKERS/MAX_PROCESSES → MAX_ORCH_CHILDREN) by @clonable-eden in #485
* feat: add CEKERNEL_MAX_ORCHESTRATORS concurrency guard to dispatch/orchestrate by @clonable-eden in #486
* docs: CLAUDE.md テスト規約に実行可能スクリプトがない変更の例外を追記 by @clonable-eden in #489
* fix: transcript-locator.sh の --worktrees- splitパターン修正 by @clonable-eden in #490
* fix: claude_session_id_persist を Orchestrator 起動後に移動 by @clonable-eden in #493
* fix: テストの set -e 耐性 — 非ゼロ返却を期待する関数呼び出しの保護 by @clonable-eden in #494
* feat: /setup に追加変数の対話設定ステップを追加 by @clonable-eden in #497
* refactor: rename claude-session-id to orchestrator.claude-session-id by @clonable-eden in #498
* README.md Structure 加筆 + plugin.json に reviewer 追加 by @clonable-eden in #503
* fix: envs/README.md + profile defaults 統一 by @clonable-eden in #504
* ADR-0008 末尾に env var catalog セクション追加 by @clonable-eden in #505
* CEKERNEL_VAR_DIR デフォルトを $HOME/.local/var/cekernel に変更 by @clonable-eden in #506
* CLAUDE.md に Review セクションを追加 (worktree Reviewer 向け) by @clonable-eden in #510
* fix: changes-requested 時に issue lock を保持して再 spawn を可能にする by @clonable-eden in #511
* Reviewer: self-review を事前検出し無駄な APPROVE/REQUEST_CHANGES を省く by @clonable-eden in #512
* fix: spawn-reviewer.sh のプロンプトから gh pr review のハードコードを削除 by @clonable-eden in #515
* Orchestrator 終了時に orchestrator.pid が削除されない問題を修正 by @clonable-eden in #516
* CLAUDE.md: 非実行ファイルへの不要テスト防止ガードレール強化 by @clonable-eden in #518
* reviewer.md の checkpoint warning 抑制と postmortem 誤検出防止 by @clonable-eden in #520
* chore(deps): update dorny/paths-filter digest to fbd0ab8 by @app/renovate in #342

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.8.0...cekernel-v1.9.0
