# cekernel-v1.7.1

## Highlights
- **Desktop notification adapter pattern**: Platform-specific notification backends (macOS, Linux, WSL) with sound, icon, and URL support
- **Orchestrator bug fix**: `/orchestrate` now correctly loads user env profiles before session ID generation

## New Features
- Desktop notification refactored to adapter pattern with per-platform backends (`macos.sh`, `linux.sh`, `wsl.sh`)
- `CEKERNEL_NOTIFY_MACOS_ACTION` environment variable for controlling URL behavior on macOS (none/open/pbcopy)
- Orchestrator passes PR URL to `desktop_notify` for click-to-open support

## Bug Fixes
- Fix `/orchestrate` skill not sourcing `load-env.sh` before `session-id.sh`, causing `CEKERNEL_VAR_DIR` to fall back to default and fail with Permission denied

## Other Changes
- WSL toast XML content verification in tests
- `CEKERNEL_NOTIFY_MACOS_ACTION` added to env var catalog

## What's Changed
* desktop-notify をアダプターパターンにリファクタリングし通知機能を拡張する by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/367
* fix: source load-env.sh before session-id.sh in /orchestrate skill by @clonable-eden in https://github.com/clonable-eden/cekernel/pull/368

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v1.7.0...cekernel-v1.7.1
