# cekernel-v1.6.0

## Highlights
- **User profile layer + `/setup` skill**: New 5th environment layer (`~/.config/cekernel/envs/`) and interactive `/setup` skill replace `Makefile`-based setup, eliminating the need for `sudo` to create runtime directories
- **Worker stdout/stderr logging**: WezTerm and tmux backends now capture Worker output to log files via `script-capture.sh`, enabling post-mortem debugging
- **orchctrl gc**: New garbage collection command cleans up stale IPC directories, FIFOs, and lockfiles from terminated or crashed Workers
- **Reviewer State Reporting**: Reviewer agent now reports its state transitions, improving observability through orchctrl
- **Reliability fixes**: Lock PID staleness detection, spawn-reviewer PR state separation, WezTerm PID resolution fallback, and headless stdout log truncation fix

## New Features
- User profile layer (Layer 4) in `load-env.sh` for user-local environment configuration
- `/setup` skill — interactive runtime directory and user profile initialization (replaces `Makefile`)
- `orchctrl gc` command for stale IPC/lock cleanup with state/handle awareness
- `script-capture.sh` helper for cross-platform stdout/stderr capture
- WezTerm and tmux backends capture Worker stdout/stderr to log files
- Reviewer agent State Reporting for orchctrl observability
- `script-capture` real-time flush and append mode

## Bug Fixes
- Fix headless backend stdout.log truncation on process switch
- Fix `orchctrl gc` stale FIFO detection with state/type awareness
- Fix WezTerm `backend_get_pid` null — tty_name-based PID fallback
- Fix `spawn-reviewer.sh` accepting separate issue and PR number arguments
- Fix `spawn.sh` lock PID staleness detection
- Fix `orchctrl ls` backend detection via metadata file
- Remove `resolve-api-key.sh` Keychain fallback (simplification)
- Fix plugin-release-tag push failure with event_name guard
- Fix marketplace update git push auth via actions/checkout migration

## Documentation
- ADR-0006 amendment: User profile layer + `/setup` skill
- Replace hardcoded paths with `$CEKERNEL_VAR_DIR` in internals.md and orchctrl SKILL.md
- Add deprecated annotations to `CEKERNEL_MAX_WORKERS` references in ADRs
- Add annotations for renamed scripts in ADRs
- Update internals.md script path references to current architecture

## Other Changes
- Refactor: reorder source and add `load-env.sh` to standalone scripts
- Refactor: remove redundant `-a` flag test cases in script-capture
- Refactor: replace command string building with file-based runner script
- Delete `Makefile` (replaced by `/setup` skill)

## What's Changed
* feat: user profile layer + /setup skill by @clonable-eden in #324
* fix: headless backend が stdout.log をトランケートする問題を修正 by @clonable-eden in #322
* docs: ADR群のCEKERNEL_MAX_WORKERS参照にdeprecated注釈を追加 by @clonable-eden in #320
* docs: ADR群の旧スクリプト名（watch-worker.sh, worker-status.sh）に括弧書き注釈を追加 by @clonable-eden in #319
* docs: internals.md のスクリプトパス参照を現行アーキテクチャに更新 by @clonable-eden in #318
* feat: script-capture にリアルタイム flush と追記モードを追加 by @clonable-eden in #314
* fix: orchctrl ls の backend 検出をメタデータ方式に変更する by @clonable-eden in #313
* feat: Reviewer agent に State Reporting を追加する by @clonable-eden in #310
* fix: resolve-api-key.sh の Keychain フォールバックを削除する by @clonable-eden in #308
* feat: wezterm/tmux バックエンドで Worker の stdout/stderr をログファイルに保存 by @clonable-eden in #306
* fix: make orchctrl gc detect and clean stale FIFOs with state/handle awareness by @clonable-eden in #304
* fix: add event_name guard to prevent push-triggered failure by @clonable-eden in #302
* fix: WezTerm backend_get_pid が null を返す — tty_name ベースの PID 取得に切り替え by @clonable-eden in #300
* fix: spawn-reviewer.sh に issue番号とPR番号を分離して渡す by @clonable-eden in #299
* feat: add orchctrl gc command for stale IPC/lock cleanup by @clonable-eden in #296
* fix: update lock PID with Worker's real process PID after spawn by @clonable-eden in #295
* fix: marketplace update step fails on git push — migrate to actions/checkout by @clonable-eden in #291

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.5.0...cekernel-v1.6.0

---

# cekernel-v1.5.0

## Highlights
- **Worker-Reviewer separation (ADR-0012)**: Workers now stop at CI pass; a separate Reviewer agent evaluates PRs before merge, providing an independent quality gate
- **Generalized process infrastructure**: Worker-specific scripts (`spawn-worker.sh`, `watch-worker.sh`, `worker-status.sh`) refactored into generic process primitives (`spawn.sh`, `watch.sh`, `process-status.sh`) supporting multiple agent types
- **Reviewer spawn + FIFO pattern**: Reviewer runs as an independent process using the same spawn + FIFO + watch infrastructure as Workers, enabling orchctrl observability
- **Desktop notifications**: New `desktop-notify` shared helper provides OS-native notifications for process lifecycle events
- **CODEOWNERS enforcement**: Added CODEOWNERS file with GitHub ruleset integration for required code owner reviews
- **Design decision guardrails**: CLAUDE.md now requires feasibility checks and ADR documentation when deviating from existing patterns

## New Features
- Add Reviewer agent definition and Orchestrator Reviewer phase (ADR-0012)
- Reduce Worker responsibility to CI pass; add `ci-passed` as valid notify-complete status
- Skip issue lock release on `ci-passed` to retain lock through review phase
- Extract `spawn.sh` common logic, wrap `spawn-worker.sh`, introduce `CEKERNEL_MAX_PROCESSES`
- Generalize `watch-worker.sh` into `watch.sh` for any process type
- Migrate `scripts/worker/` to `scripts/process/` and unify status→result
- Rename `worker-status.sh` to `process-status.sh` and add type field
- Add `--prompt` flag to `spawn.sh`; pass reviewer prompt from wrapper
- Add `spawn-reviewer.sh` wrapper for `spawn.sh --agent reviewer`
- Migrate Reviewer from subagent to spawn + FIFO pattern
- Add `desktop-notify` shared helper
- Add CODEOWNERS file for code owner review enforcement

## Bug Fixes
- Type-aware handle files to prevent Worker pane orphaning
- Add Must Not rule to prevent Agent tool language in Orchestrator prompt
- Restore `--resume` for `spawn-reviewer.sh` to reuse Worker worktree
- Fix test counter not propagating from subshell pipe
- Add Agent tool to Orchestrator for Reviewer subagent launch
- Add missing reviewer agent symlink
- Add git config for marketplace update in release workflow

## Documentation
- Add ADR-0012 worker-review-separation (draft through acceptance)
- Add CEKERNEL_AUTO_MERGE and CEKERNEL_REVIEW_MAX_RETRIES to env catalog
- Update README and internals to reflect Worker ci-passed lifecycle
- Update README Structure section with missing entries
- Fix remaining watch-worker.sh references and Structure section gaps
- Add RELEASE_NOTES.md language convention to CLAUDE.md
- Add Design Decisions guardrails to CLAUDE.md

## Other Changes
- Refactor: `spawn-reviewer.sh` always passes `--resume` internally
- Refactor: remove `watch-worker.sh` and migrate callers to `watch.sh`
- Refactor: migrate `wrapper.sh` notification to `desktop-notify` helper
- Refactor: convert notify-complete lock tests to table-driven style
- Test: add tests for spawn-reviewer, process-status, notify-complete lock, desktop-notify

## What's Changed
* docs: add ADR-0012 worker-review-separation by @clonable-eden in #245
* docs: add CEKERNEL_AUTO_MERGE and CEKERNEL_REVIEW_MAX_RETRIES to env catalog (ADR-0012) by @clonable-eden in #257
* feat: reduce Worker responsibility to CI pass (ADR-0012) by @clonable-eden in #253
* feat: add Reviewer agent definition (ADR-0012) by @clonable-eden in #254
* feat: skip issue lock release on ci-passed (ADR-0012) by @clonable-eden in #256
* feat: desktop通知の共通ヘルパー化 (ADR-0012) by @clonable-eden in #258
* feat: add CODEOWNERS and enable require_code_owner_review by @clonable-eden in #259
* feat: add Reviewer phase to Orchestrator workflow (ADR-0012) by @clonable-eden in #262
* fix: add missing reviewer agent symlink by @clonable-eden in #263
* fix: add Agent tool to Orchestrator for Reviewer subagent launch by @clonable-eden in #266
* docs: update README Structure section by @clonable-eden in #268
* feat: generalize watch-worker.sh into watch.sh by @clonable-eden in #275
* feat: spawn.sh 共通化 + spawn-worker.sh ラッパー化 + CEKERNEL_MAX_PROCESSES 導入 by @clonable-eden in #276
* feat: migrate scripts/worker/ to scripts/process/ and unify status→result by @clonable-eden in #277
* feat: rename worker-status.sh to process-status.sh and add type field by @clonable-eden in #278
* feat: Reviewer を spawn + FIFO パターンで実装 by @clonable-eden in #279
* fix: add Must Not rule to prevent Agent tool language in Orchestrator prompt by @clonable-eden in #283
* docs: fix remaining watch-worker.sh references and Structure section gaps by @clonable-eden in #284
* fix: type-aware handle files to prevent Worker pane orphaning by @clonable-eden in #286
* docs: CLAUDE.md にデザイン判断のガードレールを追加する by @clonable-eden in #288

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.4.0...cekernel-v1.5.0

---

# cekernel-v1.4.0

## Highlights
- **Scheduler infrastructure**: Added `/cron` (recurring) and `/at` (one-shot) skills powered by OS-native schedulers (macOS launchd / Linux crontab & atd)
- **Runtime unification**: Consolidated IPC directory under `/usr/local/var/cekernel/ipc/`, unifying session management and scheduler state under `CEKERNEL_VAR_DIR`
- **Issue lock**: `mkdir`-based repo × issue lockfile prevents duplicate Worker spawning for the same issue
- **tmux backend stabilization**: Fixed apostrophe quoting in prompts, added env var cleanup and server reachability check. Status promoted to Stable
- **Release automation**: Integrated CI workflow into `/release-cekernel` skill — tag, GitHub Release, and marketplace update run automatically on merge
- **MIT License added**

## New Features
- `/cron` skill — recurring schedule management (launchd/crontab)
- `/at` skill — one-shot schedule management (launchd/atd)
- Scheduler infrastructure scripts: registry.sh, wrapper.sh, resolve-api-key.sh, preflight.sh
- cron/at backend adapters (launchd, crontab, atd)
- `issue-lock.sh` — `mkdir`-based repo × issue lockfile
- Issue lock integration in spawn-worker.sh and notify-complete.sh
- Lock check added to triage protocol
- `--prompt` option for cron register
- syslog format + per-job run log (wrapper.sh)
- Launchd log artifact cleanup on cancel
- CI workflow integration + marketplace auto-update in `/release-cekernel`
- `make install` for runtime directory setup

## Bug Fixes
- tmux backend: fix shell quoting for prompts containing apostrophes (#237)
- tmux backend: unset CLAUDECODE env vars when spawning child `claude -p` (#237)
- tmux backend: add server reachability check to `backend_available()` (#237)
- Test infrastructure: use temp directory for `CEKERNEL_VAR_DIR` to fix CI permission errors
- preflight: use `resolve-api-key.sh` for API key validation
- Fix Keychain service name to "Claude Code-credentials"
- Registry: reject duplicate ID registration

## Documentation
- ADR-0011: scheduler design — launchd adoption, lock granularity, log design, `/at` backend
- README: prerequisites, first steps, scheduler backend status table, structure tree update
- internals.md: scheduler runtime, issue lock, env var cleanup
- Added `CEKERNEL_VAR_DIR` to environment variable catalog

## What's Changed
* docs: add prerequisites, notes, and first steps to README by @clonable-eden in #217
* Add MIT License to the project by @clonable-eden in #218
* docs: ADR-0011 の設計改善 — launchd 採用、ロック粒度変更、通知追加 by @clonable-eden in #221
* feat: add schedule infrastructure scripts by @clonable-eden in #222
* feat: add /cron skill — recurring schedule management by @clonable-eden in #223
* feat: add /at skill — one-shot scheduled job management by @clonable-eden in #224
* feat: integrate release workflow into skill and add marketplace auto-update by @clonable-eden in #229
* fix: move release-cekernel skill to .claude/skills/ and remove duplicate by @clonable-eden in #230
* chore: scheduler release prep — symlinks, docs, backend status by @clonable-eden in #232
* feat: scheduler log design — syslog format + per-job run log by @clonable-eden in #233
* refactor: migrate IPC directory to /usr/local/var/cekernel/ipc/ by @clonable-eden in #234
* feat: repo × issue lockfile for duplicate Worker prevention by @clonable-eden in #236
* fix: tmux backend apostrophe escape, env cleanup, and server check by @clonable-eden in #240
* docs: fix documentation gaps for 1.4.0 release by @clonable-eden in #239

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.3.0...cekernel-v1.4.0

---

# cekernel-v1.3.0

## Highlights

- **Repository restructure**: Flattened `cekernel/` subdirectory to repository root for cleaner layout
- **Rebranding**: Renamed all `glimmer` references to `cekernel`, including repository URL migration
- **Marketplace separation**: Marketplace moved to dedicated `clonable-eden/plugins` repository

## New Features

- Social preview image and updated README hero

## Bug Fixes

- Fix `.claude/` symlink targets for flattened structure
- Fix CI workflow paths for flattened structure

## Documentation

- ADR-0009 amendment: namespace detection updated to plugin.json-based approach
- Marketplace references updated to `clonable-eden/plugins`

## What's Changed
* refactor: flatten cekernel/ to repository root by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/211
* refactor: rename all glimmer references to cekernel by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/212
* docs: update marketplace references to clonable-eden/plugins by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/213
* docs: add social preview and update README hero image by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/214

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.2.1...cekernel-v1.3.0

---

# cekernel-v1.2.1

## Highlights

- **Release workflow fix**: `plugin-release.yml` changed from direct commit to PR-based flow to respect branch protection rules

## Bug Fixes

- Fix `plugin-release.yml` failing due to branch protection on direct push (#205)

## Documentation

- Update OS Analogy table with v1.2.0 concepts

## What's Changed
* docs: update OS Analogy table with v1.2.0 concepts by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/203
* fix: change plugin-release.yml from direct commit to PR-based flow by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/205

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.2.0...cekernel-v1.2.1

---

# cekernel-v1.2.0

## Highlights

- **New skills**: `/dispatch` (batch processing ready-labeled issues), `/orchctrl` (Worker control interface)
- **ADR-0008**: Orchestrator scheduling policy wired into agent prompts
- **ADR-0009**: File-based namespace detection replaces LLM-based detection
- **ADR-0010**: Worker-side environment profile loading
- **ADR-0011**: Scheduled trigger via OS-native schedulers (Accepted)
- **Headless backend improvements**: crash detection, CEKERNEL_ENV propagation, SESSION_ACCESS_TOKEN cleanup

## New Features

- `/cekernel:dispatch` skill for batch processing `ready`-labeled issues
- `/cekernel:orchctrl` skill for Worker control (ls, inspect, log, suspend, resume, term, kill, nice)
- File-based namespace detection (ADR-0009) — deterministic, no LLM inference
- Worker process crash detection in `watch-worker.sh`
- `.cekernel-env` file for reliable env propagation to Workers
- `CEKERNEL_ENV` propagation to Workers via env profiles
- Issue comments included in `.cekernel-task.md`
- `orchctrl inspect` shows detail and timestamp
- CI retry count configurable via `CEKERNEL_CI_MAX_RETRIES`
- Dynamic agent name resolution for plugin mode
- Claude Code platform constraints awareness in `/unix-architect`

## Bug Fixes

- Fix CEKERNEL_ENV propagation to Orchestrator script calls (#192)
- Fix WezTerm send-text 1024-byte truncation (#175)
- Fix `CLAUDE_CODE_SESSION_ACCESS_TOKEN` leak to child processes (#178)
- Fix `watch-worker.sh` false crash detection on headless backend
- Fix PATH and CEKERNEL_IPC_DIR propagation to Worker bash prefix
- Fix worker-state.sh IFS-sensitivity in validation

## Documentation

- ADR-0008 through ADR-0011
- README.md Structure section updated
- Internals documentation added
- WezTerm backend setup guide
- CLAUDE.md restructured

## What's Changed
* feat: resolve agent names dynamically based on plugin mode by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/131
* docs: ADR-0008 orchestrator scheduling policy by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/130
* fix: remove ${CLAUDE_PLUGIN_ROOT} from LLM-facing instructions by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/133
* feat: wire ADR-0008 scheduling policy into agent prompts by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/134
* refactor: remove CLAUDE_PLUGIN_ROOT dependency from shell scripts by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/135
* feat: add /cekernel:orchctrl skill for Worker control by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/138
* docs: add ADR-0009 file-based namespace detection by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/139
* feat: implement file-based namespace detection (ADR-0009) by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/140
* feat: add /cekernel:dispatch skill for batch processing ready-labeled issues by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/142
* fix: make worker_state_write validation immune to IFS changes by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/143
* feat: detect Worker process crash in watch-worker.sh poll loop by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/144
* test: add dispatch symlink for self-hosting by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/145
* feat: add platform constraints awareness to unix-architect skill by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/147
* fix: worker-state.sh fails fast when CEKERNEL_IPC_DIR is not set by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/148
* docs: add ADR-0010 Worker-side environment profile loading by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/149
* feat: make CI retry count configurable via CEKERNEL_CI_MAX_RETRIES by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/152
* fix: strip newlines from base64 payload in WezTerm backend by @pei0804 in https://github.com/clonable-eden/cekernel/pull/154
* feat: include detail and timestamp in orchctrl inspect output by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/156
* feat: include issue comments in .cekernel-task.md by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/157
* feat: make CI retry count configurable via CEKERNEL_ENV profile loading by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/158
* refactor: restructure cekernel/README.md by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/163
* fix: propagate PATH and CEKERNEL_IPC_DIR to Worker bash prefix by @pei0804 in https://github.com/clonable-eden/cekernel/pull/161
* refactor: restructure CLAUDE.md and cekernel/CLAUDE.md by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/166
* feat: add status job for ruleset required status check by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/168
* feat: display worker status and logs in right pane by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/171
* fix: clean up test IPC remnants in run-tests.sh by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/174
* fix: wezterm backend send-text 1024-byte truncation by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/175
* docs: add orchestrator scripts boundary rule to worker.md by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/177
* docs: add trusted config paths guidance for worktree users by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/164
* docs: document wezterm send-text 1024-byte limit in internals.md by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/181
* fix: unset CLAUDE_CODE_SESSION_ACCESS_TOKEN in headless backend by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/178
* docs: document Claude Code env var cleanup for child process spawning by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/183
* fix: watch-worker.sh WORKER_CRASH false positive on headless backend by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/184
* fix: Worker が BASH_PREFIX の $PATH を省略し基本コマンドが見つからなくなる問題を修正 by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/187
* docs: remove cekernel: namespace prefix from unix-architect SKILL.md usage by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/189
* docs: fix Related links in internals.md to point to actual issues/PRs by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/190
* docs: README.md の Structure セクションを現在のファイル構成に更新 by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/191
* fix: Orchestrator が watch-worker.sh に CEKERNEL_ENV を渡していない by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/193
* docs: add ADR-0011 scheduled trigger via OS-native schedulers by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/194

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.1.0...cekernel-v1.2.0

---

# cekernel-v1.1.0

## Highlights

- **ADR-0001 through ADR-0007**: Foundation architecture decisions established (multi-terminal backend, session memory, signal mechanism, worker state machine, headless backend, env var catalog, dual-path completion)
- **Multi-terminal backend**: WezTerm and tmux backends with pluggable adapter interface
- **Worker process model**: Formal state machine (NEW/READY/RUNNING/WAITING/TERMINATED), signal mechanism, priority (nice value), and suspend/resume
- **Headless backend**: ADR-0005 interface redesign enabling CI and non-GUI environments
- **Environment profiles**: Centralized env var catalog with `load-env.sh` profile loader

## New Features

- `/unix-architect` skill for writing ADRs and reviewing PRs
- Multi-terminal backend support with tmux backend (ADR-0001)
- Signal mechanism for async Worker control (ADR-0003)
- Session memory layer with local task file extraction (ADR-0002)
- Formal worker process state machine (ADR-0004)
- Worker priority (nice value) for resource allocation
- Context swap suspend/resume mechanism
- Headless backend and interface redesign (ADR-0005)
- Centralized env var catalog and env profiles (ADR-0006)
- Dual-path completion detection — FIFO + state fallback (ADR-0007)
- `--env` UX for orchestrate skill
- WezTerm `plugins.d` install via Makefile

## Bug Fixes

- Fix WezTerm Lua event blocking UI freeze
- Fix single quote escaping in `spawn-worker.sh` payload
- Fix `terminal_pane_alive` regex for WezTerm JSON whitespace
- Fix JSON and shell escaping separation in `spawn-worker.sh`
- Fix orchestrator subagent blocking conversation (run in background)
- Fix headless backend: unset CLAUDECODE env, add `-p` flag
- Fix dual-path completion detection (FIFO + state fallback)
- Fix WezTerm plugin `require` path for `plugins.d` compatibility

## Documentation

- ADR-0001 through ADR-0007
- Configuration section and `envs/` added to README
- Worker suspend/resume and priority documentation

## What's Changed
* docs: ADR-0001 multi-terminal backend support by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/81
* fix(cekernel): Lua イベントで Worker レイアウト構築し UI フリーズ防止 by @pei0804 in https://github.com/clonable-eden/cekernel/pull/87
* refactor: background worker monitoring with waiting queue model by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/89
* fix: escape single quotes in spawn-worker.sh prompt payload by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/92
* fix: terminal_pane_alive regex doesn't match WezTerm JSON whitespace by @pei0804 in https://github.com/clonable-eden/cekernel/pull/95
* fix: separate JSON and shell escaping in spawn-worker.sh payload by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/96
* feat: multi-terminal backend support (wezterm/tmux) by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/97
* feat: add signal mechanism for async Worker control by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/98
* feat: add session memory layer with local task file extraction by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/99
* feat: add formal worker process state machine by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/100
* feat: add Worker priority (nice value) for resource allocation by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/102
* feat: add context swap suspend/resume mechanism by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/103
* fix: run orchestrator subagent in background by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/104
* docs: ADR-0005 headless backend and interface redesign by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/106
* feat: headless backend and interface redesign (ADR-0005) by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/107
* docs: ADR-0006 centralized env var catalog and profiles by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/110
* feat: centralized env var catalog and env profiles by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/111
* docs: add Configuration section and envs/ to README by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/112
* docs: ADR-0007 dual-path completion detection by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/113
* feat: wire env profile integration and add --env UX to orchestrate skill by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/115
* fix: dual-path completion detection (FIFO + state fallback) by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/118
* fix: unset CLAUDECODE env and add -p flag in headless backend by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/119
* feat: WezTerm plugins.d install for cekernel by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/120
* docs: update README with WezTerm plugin install by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/121

## New Contributors
* @pei0804 made their first contribution in https://github.com/clonable-eden/cekernel/pull/87

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.0.0...cekernel-v1.1.0

---

# cekernel-v1.0.0

## Highlights

- **Breaking rename**: `kernel` → `cekernel` across the entire codebase (env vars, IPC paths, scripts, documentation)
- **English-first documentation**: All documentation, script comments, and agent/skill definitions converted to English
- **Marketplace update**: Plugin name and source updated for the cekernel rename

## Breaking Changes

- All `KERNEL_*` environment variables renamed to `CEKERNEL_*`
- IPC paths changed from `kernel` to `cekernel` namespace
- Plugin name changed from `kernel` to `cekernel` in marketplace

## Documentation

- All script comments converted to English
- All agent and skill definitions converted to English
- Root documentation and marketplace metadata converted to English

## What's Changed
* refactor: rename kernel env vars and IPC paths to cekernel namespace by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/67
* feat!: rename kernel to cekernel by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/68
* docs: convert all Japanese text to English for v1.0.0 by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/70
* docs: fix missed items in English conversion by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/71
* fix: update marketplace.json for cekernel rename by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/73

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/kernel-v0.7.1...cekernel-v1.0.0
