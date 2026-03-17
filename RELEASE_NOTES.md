# cekernel-v1.8.0

## Highlights
- **PATH inheritance by design**: Runner script / headless backend now source `.cekernel-env` before launching `claude -p`, eliminating the need for LLM to prefix every Bash command with `source .cekernel-env &&`
- **Standalone commands**: Converted `worker-state-write.sh`, `create-checkpoint.sh`, `clear-resume-marker.sh` to standalone executables, eliminating the zsh `source` incompatibility at its root
- **CEKERNEL_SCRIPTS propagation**: Skills now resolve script paths via `${CLAUDE_SKILL_DIR}` and propagate the absolute path to the Orchestrator via prompt
- **Full zsh compatibility**: Applied `BASH_SOURCE[0]` zsh fallback (`${(%):-%x}`) to all shared scripts. Fixed desktop-notify silently becoming a no-op in zsh environments
- **phase-transition.sh**: Combines signal check and state write into a single command, structurally preventing signal check omission at phase boundaries
- **TDD commit rules**: Worker agent definition now explicitly requires RED/GREEN/REFACTOR commits at each step
- **orchctrl repo metadata**: Added `org/repo` format display and separated `CEKERNEL_SESSION_ID` from `CLAUDE_SESSION_ID`

## New Features
- Source .cekernel-env in runner/headless to propagate PATH (#389)
- Add standalone process commands for LLM agents (#390)
- Use CLAUDE_SKILL_DIR for scripts path resolution and propagate to Orchestrator (#392)
- Add CEKERNEL_SCRIPTS propagation and use variable refs in orchestrator.md (#392)
- Add phase-transition.sh to combine signal check and state write (#400)
- orchctrl reads repo name from IPC metadata file (#408)
- Add "Direct push to main branch" pattern to postmortem-patterns.md (#384)

## Bug Fixes
- Source load-env.sh in all orchestrator scripts before session-id.sh (#377)
- Resolve load-env.sh from CEKERNEL_SCRIPTS when BASH_SOURCE fails (#376)
- Source session-id.sh and propagate CEKERNEL_SESSION_ID in /dispatch skill (#375)
- Replace declare -A with temp file in orchctrl gc for bash 3.2 compat (#383)
- Replace flaky sleep with polling in test-agent-name-resolution (#385)
- Remove redundant SESSION_ID export from runner.sh and fix test numbering (#389)
- Use cd -P for CEKERNEL_SCRIPTS resolution via symlinks (#402)
- Use zsh-compatible BASH_SOURCE fallback for path resolution (#404)
- Apply BASH_SOURCE[0] zsh fallback to load-env.sh and backends (#406)
- Separate CEKERNEL_SESSION_ID from CLAUDE_SESSION_ID in skills (#408)
- Replace gh repo view with git config for repo slug resolution (#408)
- Exclude ORIG_PATH from Test 11 to prevent real osascript notifications (#401)

## Documentation
- Add Scripts Path Resolution section to namespace-detection.md (#392)
- Add BASH_SOURCE zsh fallback to Known Pitfalls (#404)
- Inline TDD commit rules in worker agent definition (#398)
- Add Script Invocation section to worker and reviewer agents (#410)
- Simplify RELEASE_NOTES.md to latest release only (#371)
- Add CEKERNEL_SESSION_ID to orchestrate skill prompt bullet (#375)

## Other Changes
- refactor: move wait_for_file to helpers.sh for reuse across tests (#385)
- test: add orchctrl repo metadata file tests (#408)
- test: add zsh compatibility tests for BASH_SOURCE path resolution (#404, #406)

## What's Changed
* docs: simplify RELEASE_NOTES.md to latest release only by @clonable-eden in #371
* fix: source session-id.sh and propagate CEKERNEL_SESSION_ID in /dispatch skill by @clonable-eden in #375
* fix: resolve load-env.sh from CEKERNEL_SCRIPTS when BASH_SOURCE fails by @clonable-eden in #376
* fix: source load-env.sh in all orchestrator scripts before session-id.sh by @clonable-eden in #377
* fix: replace declare -A with temp file in orchctrl gc for bash 3.2 compat by @clonable-eden in #383
* postmortem-patterns.md に「Direct push to main branch」パターンを追加 by @clonable-eden in #384
* fix: replace flaky sleep with polling in test-agent-name-resolution by @clonable-eden in #385
* feat: source .cekernel-env in runner/headless to propagate PATH by @clonable-eden in #389
* feat: LLMがsourceする共有スクリプトをstandaloneコマンドに変換する by @clonable-eden in #390
* feat: use CLAUDE_SKILL_DIR for scripts path resolution and propagate to Orchestrator by @clonable-eden in #392
* Worker agent 定義に TDD コミットルールを直接記載する by @clonable-eden in #398
* feat: add phase-transition.sh to combine signal check and state write by @clonable-eden in #400
* fix: desktop-notify.sh テスト中に実通知が飛ぶ問題を修正 by @clonable-eden in #401
* fix: use cd -P for CEKERNEL_SCRIPTS resolution via symlinks by @clonable-eden in #402
* fix: BASH_SOURCE zsh互換フォールバックでdesktop-notify/issue-lockのno-op問題を修正 by @clonable-eden in #404
* fix: apply BASH_SOURCE[0] zsh fallback to remaining shared scripts by @clonable-eden in #406
* fix: plugin モードで CEKERNEL_SESSION_ID が UUID 形式になる問題を修正 by @clonable-eden in #408
* docs: add Script Invocation section to worker and reviewer agents by @clonable-eden in #410

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.7.1...cekernel-v1.8.0
