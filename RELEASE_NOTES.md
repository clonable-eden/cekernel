# cekernel-v2.1.1

## Highlights

- **Orchestrator env delivery via file (#652)**: `spawn-orchestrator.sh` が `env.sh` を生成し、Orchestrator が毎 Bash call で source する方式に変更。daemon 経由の env 配送が不確実だった問題 (#641-644) を解消し、inline export への退化を排除。`verify-env.sh` による startup 検証も追加。
- **Release body の silent 空公開を防止 (#654)**: `plugin-release-tag.yml` が抽出結果の空を検知し `--generate-notes` にフォールバック。SKILL.md のヘッダ書式も `# cekernel-v${VERSION}` に固定。
- **watch.sh 誤完了 banner の修正 (#651)**: chunk timeout 時に「All workers finished」と誤表示する問題を修正。真の完了時のみ banner を出力するようゲート。
- **Renovate で bats-core バージョンを追従 (#655)**: CI の `git clone --branch vX.Y.Z` pin を customManager(regex) で検知対象に追加。

## Bug Fixes

- fix: prevent silent empty release body and fix header format mismatch (#657, closes #654)
- fix: gate "All workers finished" banner to true terminal states only (#658, closes #651)
- fix: explicitly write required vars in env.sh generation (#661, closes #652)

## New Features

- feat: add Renovate customManager for bats-core version tracking (#656, closes #655)
- feat: generate env.sh in spawn-orchestrator.sh for reliable env delivery (#661, closes #652)
- feat: add verify-env.sh for CEKERNEL_* env validation (#661, closes #652)

## What's Changed

* feat: add Renovate customManager for bats-core version tracking by @clonable-eden in #656
* fix: release body 空公開の防止とヘッダ書式の固定 by @clonable-eden in #657
* fix: watch.sh が chunk timeout 時に誤った完了 banner を出力する問題を修正 by @clonable-eden in #658
* feat: env.sh ファイル経由の Orchestrator env 配送 (#652) by @clonable-eden in #661

**Full Changelog**: https://github.com/clonable-eden/cekernel/compare/cekernel-v2.1.0...cekernel-v2.1.1
