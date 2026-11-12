# PhotoTriage

Sort, de-duplicate and triage large photo and video archives by camera, safely.

[![Tests](https://github.com/pedrocsilva/phototriage/actions/workflows/tests.yml/badge.svg)](https://github.com/pedrocsilva/phototriage/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

PowerShell 7 scripts on top of [ExifTool](https://exiftool.org), built for archives with hundreds of thousands of files collected over decades from many cameras and phones.

- **Sort** files into `RAW / JPG / VIDEO / ELSE` folders per camera model.
- **Find duplicates** by content (SHA-256) and prune them after review.
- **Pair** RAW + JPG, RAW + RAW (e.g. RAF + DNG) and Apple Live Photos.
- **Undo** any run from its log.

> [!WARNING]
> **Back up your archive first.** These scripts move and can delete files. They preview by default and are tested not to lose data, but keep a verified backup on another drive, read the preview log, and only then add `-Action Move` or `-Action Delete`. Provided as is, without warranty ([MIT](./LICENSE)).

## Quick start

Requires [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) and ExifTool (`winget install PhilHarvey.ExifTool`, `brew install exiftool` or `apt install libimage-exiftool-perl`).

```powershell
# 1. See what is in the archive
pwsh scripts/Get-MediaInventory.ps1 -Path "D:\Photos"

# 2. Preview the sort; the full plan is written to D:\Sorted\_logs\
pwsh scripts/Reorg-Media.ps1 -Source "D:\Photos" -DestRoot "D:\Sorted"

# 3. Sort for real
pwsh scripts/Reorg-Media.ps1 -Source "D:\Photos" -DestRoot "D:\Sorted" -Action Move

# Changed your mind? Undo using the run's log
pwsh scripts/Undo-Moves.ps1 -Log "D:\Sorted\_logs\reorg_<timestamp>.log" -Action Move
```

Result:

```
D:\Sorted\
├─ RAW\Sony A7 IV\
├─ JPG\Apple iPhone 15 Pro Max\
├─ VIDEO\Google Nexus 5\
├─ ELSE\UNKNOWN\          # no camera in EXIF (scans, screenshots, ...)
└─ _logs\
```

## Scripts

| Script | What it does | Changes files | Default |
| ------ | ------------ | ------------- | ------- |
| `Get-MediaInventory` | Files and size per extension, and which bucket each goes to | No | — |
| `List-Models` | Cameras found in EXIF, file counts, folder name each maps to | No | — |
| `Reorg-Media` | Sort into `<Bucket>/<Camera>/` | Moves | preview |
| `Merge-Model-Folders` | Merge alias folders (`iPhone 14 Pro` → `Apple iPhone 14 Pro`) after editing the model map | Moves | preview |
| `Reclassify-MediaTree` | Regroup into `Cameras / Phones / Others/<Camera>/<Bucket>` | Moves | preview |
| `Validate-Placement` | Find (and fix) files in the wrong camera or bucket folder | Moves | report |
| `Find-Duplicates` | Find byte-identical files per camera; move each set into a review folder | Moves | report |
| `Prune-Duplicate-Groups` | Keep one file per reviewed duplicate set | **Deletes** | report |
| `Find-RawJpg-Pairs` | RAW + JPG of the same shot; move the smaller one to review | Moves | report |
| `Find-Raw-Format-Pairs` | Same shot saved in two RAW formats | No | — |
| `Find-LivePhoto-Pairs` | Apple Live Photo still + video pairs | No | — |
| `Undo-Moves` | Reverse the moves recorded in one or more logs | Moves | preview |

Every script prints its options with `Get-Help scripts/<Name>.ps1 -Full`. Scripts that change files take `-Action` (see the table) and `-WhatIf`, which always forces a preview. Most take `-Stage RAW|JPG|VIDEO|ELSE|ALL`.

## Safety

Each guarantee below is covered by [`tests/Validate-Safety.ps1`](./tests/Validate-Safety.ps1).

- **Preview first.** Nothing moves or is deleted without `-Action Move` / `-Action Delete`. Previews reserve target names, so they show exactly what a real run would do.
- **No overwrites.** Name clashes get `__1`, `__2`, ... suffixes.
- **Crash safe.** Same-drive moves are atomic renames. Cross-drive moves copy to `*.phototriage-partial`, check the size, rename, then delete the original, so a half-copied file never takes the real name. Rerunning after `Ctrl+C` or a crash finishes the job without losing files (tested by killing runs mid-way). The one edge case: a cross-drive move killed between its last two steps leaves that single file in both places; `Find-Duplicates` finds it.
- **Verified deletes.** `Prune-Duplicate-Groups` only works inside folders created by `Find-Duplicates`, re-hashes every file, and keeps anything that is not byte-identical. Deletes are permanent.
- **Untrusted EXIF.** Camera names are sanitized: no `..`, hidden, reserved (`NUL`, `CON`) or nested folders.
- **Fail closed.** Missing ExifTool or unreadable output stops the run before anything moves.
- **Complete logs.** Every move and delete is written to `_logs/` the moment it happens, which is also what makes `Undo-Moves` possible.

Exit codes: `0` ok, `1` unreadable ExifTool output, `2` missing ExifTool or input, `3` some files failed (see the log).

## Platforms

| | Status |
| - | ------ |
| Windows 10/11 | Primary platform, used on multi-terabyte archives. Tested in CI. |
| macOS, Linux | Tested in CI. Not yet used on a large real archive. |

Requires PowerShell 7.4 or newer (`pwsh`); Windows PowerShell 5.1 is not supported. Tests use placeholder files and a fake ExifTool, so they verify file handling, not ExifTool itself.

## Performance

ExifTool is called once per run for the whole tree and only reads extensions that can be sorted (sidecars, thumbnails and documents are skipped). Moving is about 3,000 files/s on an SSD (20,000-file benchmark, macOS), so on large archives ExifTool's scan dominates. `Find-Duplicates` only hashes files that share a size and extension.

## Camera names

[`modules/ModelMap.ps1`](./modules/ModelMap.ps1) maps raw EXIF names to folder names, e.g. `ILCE-7M4` → `Sony A7 IV`. Run `List-Models` to see unmapped cameras, add them, then run `Merge-Model-Folders` to fold old folders into the new names.

## Supported formats

| Bucket | Extensions |
| ------ | ---------- |
| RAW | arw, cr2, dng, gpr, nef, orf, raf |
| JPG | jpg, jpeg, heic |
| VIDEO | mov, mp4, mpg |
| ELSE | gif, png, tif, tiff |

Other files are left where they are. Buckets are defined once in [`modules/PhotoTriage.psm1`](./modules/PhotoTriage.psm1).

## Development

```powershell
pwsh tests/Run-All.ps1
```

CI runs the suite on Windows, macOS and Linux. See [tests/README.md](./tests/README.md) and [CHANGELOG.md](./CHANGELOG.md).

## License

[MIT](./LICENSE) © 2026 Pedro C. Silva
