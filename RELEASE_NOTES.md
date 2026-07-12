# cekernel-v2.2.0

## Highlights

- **Reviewer result handling redesigned (ADR-0021 Amendment 2, #646)**: the Reviewer's GitHub review posting is now **explicitly authorized in the prompt**, eliminating the intermittent `[External-Write]` security-classifier false positive (probe-verified: 3/3 fired without authorization, 0/3 with). The verdict vocabulary is **locked to a canonical enum** (`approved / changes-requested / failed` — `reviewer_state_write` rejects anything else), and **escalation no longer destroys the worktree/lock** — it posts a runbook comment on the issue and preserves state for human disposition.
- **SECURITY WARNING reason-based routing (#669)**: transient `Stage 2 classifier error` warnings no longer trigger escalation — the Orchestrator adopts the Reviewer's verdict and proceeds. Actionable signals (`[External-Write]`, `[Self-Approval]`) and unrecognized warnings still escalate (fail-safe).
- **Worker CI wait primitive (#650)**: new `wait-ci.sh` gives Workers a sanctioned foreground blocking wait (540s chunks, `passed/failed/watching` JSON), ending the 39–143-poll busy-wait pattern observed in postmortems.
- **`orchctl` simplified (#659, #660)**: `inspect` is removed (fully covered by `ls`), and `ps` now emits **JSON Lines** like `ls` — shell users compose with `jq`, the `/orchctl` skill renders tables.
- **`orchctl gc` closes the resource-leak loop (#671, #678)**: gc now sweeps **escalation residue** (worktrees/locks whose PR is merged or closed — open PRs are never touched), **reviewer IPC files**, and **`env.sh`**, so session directories are actually reclaimed. Verified live: 11 stale resources cleaned on first run.
- **Codebase hygiene (#672)**: 4 dead functions removed, `format_elapsed` extracted to a shared helper, agent-definition misinformation fixed (`CEKERNEL_MAX_ORCH_CHILDREN` default is 5, workers only), IPC layout and env-var catalog documentation brought up to date.

## New Features

- feat: ADR-0021 Amendment 2 — Reviewer result handling (α authorization / β verdict enum / γ escalation without cleanup) (#663, closes #646)
- feat: add wait-ci.sh foreground blocking CI wait primitive + Worker Protocol update (#664, closes #650)
- feat: remove orchctl inspect, consolidate into ls (#665, closes #659)
- feat: change orchctl.sh ps output to JSON Lines (#666, closes #660)
- feat: add escalation-residue sweep to orchctl gc (worktree/lock vs PR state) (#676, closes #671)

## Bug Fixes

- fix: add reason-based routing to SECURITY WARNING check (transient classifier errors no longer escalate) (#670, closes #669)
- fix: hygiene batch — agent-doc corrections, dead function removal, format_elapsed dedup, gc env.sh deletion (#677, closes #672)
- fix: gc sweeps reviewer IPC files and legacy claude-session-id so session dirs are reclaimed (#679, closes #678)

## Documentation

- docs: update README.md for ADR-0021 and inspect removal (#668, closes #667)
- docs: document IPC layout files and CEKERNEL_GC_STALE_TIMEOUT (#677)

## What's Changed

* feat: ADR-0021 Amendment 2 — Reviewer result handling (#646) by @clonable-eden in #663
* feat: Worker CI待ちブロッキング primitive (wait-ci.sh) by @clonable-eden in #664
* feat: remove orchctl inspect, consolidate into ls by @clonable-eden in #665
* feat: orchctl.sh ps を JSON Lines 出力に変更 by @clonable-eden in #666
* docs: update README.md for ADR-0021 and inspect removal by @clonable-eden in #668
* fix: add reason-based routing to SECURITY WARNING check by @clonable-eden in #670
* feat: add escalation-residue sweep to orchctl gc (worktree/lock vs PR state) by @clonable-eden in #676
* 衛生系まとめ: docs 誤記修正・dead functions 削除・format_elapsed 共通化・gc の env.sh 削除漏れ (#672) by @clonable-eden in #677
* fix: gc sweeps reviewer IPC files so session dirs are reclaimed by @clonable-eden in #679

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v2.1.1...cekernel-v2.2.0
