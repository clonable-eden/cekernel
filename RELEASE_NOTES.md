# cekernel v2.1.0

## Highlights

- **Completion detection simplified (ADR-0020)**: the completion-notification **FIFO is retired**. Slot accounting, roster enumeration, and completion payloads now live in **state files**, cutting the three completion-detection sources down to two plus separated polling. Fewer moving parts, no FIFO liveness edge cases.
- **Reviewer subagent contract consolidated (ADR-0021)**: the Reviewer **no longer uses a platform-managed `isolation: worktree`** — it reads the Worker's existing worktree **read-only** (PR-anchored), so the `--bg` worktree leak is closed by construction. Reviewer state is now **visible in `orchctl ls`/`ps`**, and the verdict travels **out-of-band** with no approval-word leaked into the GitHub comment (the Orchestrator no longer swallows a SECURITY WARNING).
- **bats-core migration completed (ADR-0021 test overhaul, #609)**: the legacy `test-*.sh` harness and `run-tests.sh` are **fully removed**; CI runs **`bats --recursive tests/`** exclusively.
- **v2 regression fixes**: `gc` now respects v2 opaque session tokens when reaping locks/logs (#619), `claude stop` receives the short session id (#626), `watch.sh` uses chunk-based sentinel exit with cumulative elapsed (#630), and `session-id.sh` reads the provisioned id from the worktree (#632).
- **Reviewer liveness matrix updated** for claude 2.1.205: `idle/working` between turns is now correctly treated as **alive** (#638).

## New Features

- feat: unix-architect — add code cross-check verification of factual claims to review mode (#612)
- feat: drop `isolation: worktree` from the Reviewer — borrow the Worker's worktree read-only (#636)
- feat: surface reviewer state in `orchctl ls`/`ps` (#637)

## Bug Fixes

- fix: `gc` lock/log reap respects v2 opaque session tokens (#620, closes #619)
- fix: unset `CEKERNEL_SESSION_ID` in Step D to force new session scope (#625)
- fix: `claude_bg_stop` passed a full UUID to `claude stop`, so stops always failed (#626)
- fix: `session-id.sh` reads the provisioned id from `.cekernel-env` in the worktree (#632)
- fix: `watch.sh` chunk-based sentinel exit and cumulative elapsed (#633, closes #630)
- fix: prevent Reviewer approval-word leakage and Orchestrator SECURITY WARNING bypass (#639, closes #628)
- fix: add `idle/working → alive` to the liveness matrix (#640, closes #638)

## Documentation

- docs: ADR-0020 — retire the completion-detection FIFO (3 sources → 2 sources + separated polling) (#610)
- docs: #595 — layer 2 is the auto-mode classifier (mechanism confirmed) (#617)
- docs: ADR-0021 — Reviewer subagent contract (#634)
- docs: ADR-0021 Decision 1 — mechanism to principle (reuse Worker worktree) (#635)

## Other Changes

- refactor: ADR-0020 Phase 1a — consolidate completion payload into state files (#618)
- refactor: ADR-0020 Phase 1 — state-file-based slot accounting + reaper/resolver/orchestrator wiring (#623)
- refactor: ADR-0020 Phase 2 — state-based roster enumeration + gc reap write (#624)
- refactor: ADR-0020 Phase 3+4 — remove FIFO creation/write/read paths + document sweep (#631)
- test: bats migration A群 — reconcile 16 duplicate tests against bats coverage, delete legacy (#645, #609)
- test: bats migration B群 (orchestrator) — migrate/delete 8 unported tests (#647, #642)
- test: bats migration B群 (process+shared) — migrate/delete 11 unported tests (#648, #643)
- test: bats migration finalize — delete `run-tests.sh`, switch CI to bats-only (#649, #609)
- chore(deps): update dorny/paths-filter digest to 7b450ff (#542)

## What's Changed

* docs: ADR-0020 — 完了検知 FIFO の退役(3ソース → 2ソース + 分離ポーリング) by @clonable-eden in #610
* feat: unix-architect — review モードに事実主張のコード突き合わせ検証を追加 by @clonable-eden in #612
* docs: #595 — 層2は auto モード classifier(機序確定) by @clonable-eden in #617
* refactor: ADR-0020 Phase 1a — 完了 payload を state ファイルに集約 by @clonable-eden in #618
* fix: gc lock/log reap respects v2 opaque session tokens (#619) by @clonable-eden in #620
* refactor: ADR-0020 Phase 1 — 状態ファイルベースの slot 会計 + reaper/resolver/orchestrator 配線 by @clonable-eden in #623
* refactor: ADR-0020 Phase 2 — state-based roster enumeration + gc reap write by @clonable-eden in #624
* fix: unset CEKERNEL_SESSION_ID in Step D to force new session scope by @clonable-eden in #625
* fix: claude_bg_stop がフル UUID を claude stop に渡し停止が常に失敗する問題を修正 by @clonable-eden in #626
* refactor: ADR-0020 Phase 3+4 — remove FIFO creation, write, read paths + document sweep by @clonable-eden in #631
* fix: session-id.sh reads provisioned ID from .cekernel-env in worktree by @clonable-eden in #632
* fix: watch.sh chunk-based sentinel exit and cumulative elapsed (#630) by @clonable-eden in #633
* docs: ADR-0021 — Reviewer subagent contract by @clonable-eden in #634
* docs: ADR-0021 Decision 1 — mechanism to principle (reuse Worker worktree) by @clonable-eden in #635
* feat: drop isolation: worktree from Reviewer — borrow Worker's worktree read-only by @clonable-eden in #636
* feat: surface reviewer state in orchctl ls/ps (#627) by @clonable-eden in #637
* fix: prevent Reviewer approval-word leakage and Orchestrator SECURITY WARNING bypass (#628) by @clonable-eden in #639
* fix: add idle/working → alive to liveness matrix (#638) by @clonable-eden in #640
* test: bats 移行 A群 — 重複16本のカバレッジ突合→legacy削除(#609) by @clonable-eden in #645
* test: bats 移行 B群(orchestrator)— 未対応8本を移行/削除 (#642) by @clonable-eden in #647
* test: bats 移行 B群(process+shared)— 未対応11本を移行/削除(#643) by @clonable-eden in #648
* test: bats 移行仕上げ — run-tests.sh 削除・CI 単独化 (#609) by @clonable-eden in #649
* chore(deps): update dorny/paths-filter digest to 7b450ff by @app/renovate in #542

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v2.0.0...cekernel-v2.1.0
