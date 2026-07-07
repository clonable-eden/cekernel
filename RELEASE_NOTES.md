# cekernel-v2.0.0

cekernel 2.0 replaces the `claude -p` fork model with **`claude --bg` background
agent sessions** supervised by an on-demand daemon. Spawned Workers and
Orchestrators now survive the dispatching session's turn boundary — the failure
that silently killed `-p` Orchestrators — and `claude agents --json` becomes the
authoritative process roster.

**This is a breaking release.** The `-p` spawn paths are removed outright; there
is no runtime compatibility switch. Operators who need the old behavior stay on
the `1.9.x` line (see **Migration** below). Requires a recent Claude Code
(verified against **v2.1.202**; subagent nesting needs ≥ v2.1.172).

## Highlights

- **`claude --bg` spawn delegation (ADR-0016)**: Orchestrators, Workers, and the
  wrapper/scheduler paths all spawn as `claude --bg` sessions; session IDs are
  captured from the spawn line (not injected), and the daemon supervises
  liveness. Fixes the `-p` turn-end silent-death class (#558 family).
- **Platform interface contracts (ADR-0018)**: `scripts/shared/claude-bg.sh` is
  the **sole owner** of the claude CLI surface. Raw platform JSON never crosses
  the module boundary; consumers use semantic verdict predicates
  (`alive` / `blocked` / `terminal` / `not-listed` / `query-failed` /
  `unknown-value`). Ends the scattershot drift-patch cycle (#581 → #584 → #591 →
  #589) by giving each boundary one guarantor.
- **Reviewer as an Orchestrator subagent (ADR-0012 Amendment 2)**: the Reviewer
  moved from a spawned `-p` process to an `isolation: worktree` subagent that
  does a detached PR checkout and returns its verdict as its final line.
- **Test suite overhaul (ADR-0017)**: migration to **bats-core**, PATH-shim
  mocks (`mock-bin` / `mock-claude` as the executable contract spec), test-file
  consolidation, and a hard ban on content-based assertions over markdown /
  non-executable files ("assert behavior, never text").
- **Worker lifecycle Stop hook (ADR-0019)**: a plugin `Stop` hook keeps a Worker
  session alive until `notify-complete.sh` records `TERMINATED`, closing the
  "Worker dies before its completion notification" gap. Live-verified to fire in
  both local self-hosting and plugin-installed usage (via spawn-time
  `--plugin-dir`).
- **/workflows boundary (ADR-0015)**: state that survives the session belongs to
  cekernel; in-session fan-out belongs to `/workflows` — documented usage guide.
- **Conditional `--bare` (ADR-0016 Amendment 1)**: bare mode is now selected by
  auth availability — OAuth/subscription operators spawn plain `--bg` (no
  forced `ANTHROPIC_API_KEY`), API-key operators get `--bare` + explicit context.

## ⚠️ Breaking Changes

- **`claude -p` spawn paths removed.** No `CEKERNEL_SPAWN_MODE` switch, no
  runtime fallback. Every spawn (Orchestrator, Worker, wrapper/scheduler,
  backends) goes through `claude --bg`.
- **Backend contract revised (#572, #578, #585)**: headless/wezterm/tmux
  backends spawn `--bg` then `claude attach <id>`; the registry's stored value
  and semantics changed.
- **Daemon-inherited session env is unspecified (ADR-0018 §3)**: no cekernel
  code may rely on it; spawners inject `CEKERNEL_*` explicitly. Custom callers
  that leaned on env inheritance must inject their own.
- **Requires a recent Claude Code** (`--bg`, `agents --json`, subagent nesting,
  `additionalContext` hooks). Older CLIs are unsupported.

## Migration

- **Update Claude Code** to a current release (verified against v2.1.202).
- **Update the plugin** (`/plugin update cekernel`) — no config migration is
  required for the common OAuth/subscription setup; spawns default to plain
  `--bg`.
- **API-key / headless operators**: `--bare` still applies when
  `ANTHROPIC_API_KEY` or `CEKERNEL_CLAUDE_SETTINGS` (with `apiKeyHelper`) is
  present; scheduled `wrapper.sh` paths still hard-require it (fail noisily
  rather than expire silently).
- **Staying on 1.x**: if you depend on `-p` spawning, pin to `cekernel-v1.9.x`.
  The 1.x line is the supported legacy mode; 2.0 does not run alongside it.

## Known Issues

- **Reviewer worktrees are not auto-cleaned under `--bg`**
  ([#602](https://github.com/clonable-eden/cekernel/issues/602)): when the
  Orchestrator runs non-interactively (`claude --bg`, the default in 2.0), the
  platform's worktree auto-cleanup and `.git/info/exclude` auto-ignore do
  **not** fire on Reviewer (`isolation: worktree`) subagent completion.
  Leftover `.claude/worktrees/agent-*` accumulate on disk and show as
  untracked `?? .claude/worktrees/` in `git status`. **Workaround**:
  periodically run `git worktree prune` / `git worktree remove`. Left
  intentionally visible (not gitignored) as a cleanup signal. The root fix —
  moving the Reviewer onto a cekernel-managed worktree — is tracked in #602
  and scheduled post-2.0.

## Architecture Decisions

This release lands five ADRs: **0015** (/workflows boundary), **0016** (`--bg`
spawn delegation, + Amendment 1 conditional `--bare`), **0017** (test-suite
overhaul), **0018** (platform interface contracts), **0019** (Worker lifecycle
Stop hook). ADR-0012 gains Amendments 2–5 (Reviewer subagent, KEEP_WORKTREE,
permission portability, namespace-agnostic Reviewer grant — the #600 fix).

## What's Changed

* feat: add CEKERNEL_KEEP_WORKTREE to preserve worktree after Reviewer approval by @clonable-eden in #559
* test: bats-core ハーネス bootstrap + CI dual-lane by @clonable-eden in #560
* feat: Reviewer を Orchestrator subagent 化(ADR-0012 Amendment 2 実装) by @clonable-eden in #561
* feat: default all spawn paths to --bare explicit context (ADR-0016 Phase 0) by @clonable-eden in #563
* test: mock-bin / mock-claude 共通モックヘルパー (ADR-0017) by @clonable-eden in #564
* feat: spawn.sh に --fallback-model パススルー追加 by @clonable-eden in #565
* feat: spawn.sh の cross-repo Issue サポート (--repo フラグ) by @clonable-eden in #566
* fix: propagate spawn.sh base branch to Worker via task file frontmatter by @clonable-eden in #567
* test: 統合バッチ1 — zsh-compat / load-env / issue-lock を .bats に統合 by @clonable-eden in #568
* test: 統合バッチ3 — scheduler マトリクス 9→5 に統合 (ADR-0017) by @clonable-eden in #569
* test: 統合バッチ2 — notify-complete / process-status / orchctl を .bats に統合 by @clonable-eden in #570
* feat: headless backend を claude --bg 化 + session-ID 捕捉 + backend 契約改訂 (ADR-0016 Phase 1) by @clonable-eden in #572
* docs: ADR-0015 follow-ups — README 使い分けガイド + agent 定義への注記 by @clonable-eden in #575
* fix: --bare を auth 可用性による条件付きに(ADR-0016 Amendment 1) by @clonable-eden in #576
* feat: Phase 5 — wezterm/tmux backend を claude attach UX に再構築 by @clonable-eden in #578
* feat: Phase 2 — spawn-orchestrator.sh を claude --bg 化 by @clonable-eden in #580
* feat: Phase 4 — orchctl ps を claude agents --json の view 層に by @clonable-eden in #582
* feat: Worker lifecycle Stop hook guard via additionalContext (ADR-0018) by @clonable-eden in #583
* fix: prefer status over state when reading claude agents --json liveness by @clonable-eden in #584
* feat: Phase 3 — wrapper.sh を claude --bg 化 + registry 意味論変更 by @clonable-eden in #585
* refactor: agents/skills markdown のスリム化 — 指示のみに縮退、env 儀式の撤去 by @clonable-eden in #590
* fix: PR #572 レビューの非ブロッキング指摘 5 件のフォローアップ by @clonable-eden in #592
* feat: ADR-0018 実装 — claude CLI 契約層の確立(#591/#589 を契約内で修正) by @clonable-eden in #596
* feat: Worker spawn 前の粗い permission preflight(ADR-0012 Amendment 4 層1) by @clonable-eden in #597

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.9.0...cekernel-v2.0.0
