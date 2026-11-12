# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-12

First public release.

### Scripts

- `Reorg-Media`: sort files into `<Bucket>/<Camera>/` from EXIF.
- `Merge-Model-Folders`, `Reclassify-MediaTree`, `Validate-Placement`: reshape and check an existing sorted tree.
- `Find-Duplicates`, `Prune-Duplicate-Groups`: content-based duplicate review and pruning.
- `Find-RawJpg-Pairs`, `Find-Raw-Format-Pairs`, `Find-LivePhoto-Pairs`: pair detection.
- `Get-MediaInventory`, `List-Models`: read-only archive overview.
- `Undo-Moves`: reverse any run from its log.

### Safety

- Every script that changes files previews by default and needs an explicit `-Action`.
- Files are never overwritten; same-drive moves are atomic and cross-drive moves are copy, verify, rename.
- Deletes only remove files verified byte-identical (SHA-256) to the copy that is kept.
- Every move and delete is logged as it happens; interrupted runs can be rerun or undone.
- EXIF camera names are sanitized before they become folder names.
- Test suite with real mid-run process kills, run in CI on Windows, macOS and Linux.

[Unreleased]: https://github.com/pedrocsilva/phototriage/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/pedrocsilva/phototriage/releases/tag/v1.0.0
