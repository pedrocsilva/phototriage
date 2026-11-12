# Tests

```powershell
pwsh tests/Run-All.ps1                              # everything
pwsh tests/Validate-Safety.ps1 -KeepTemp            # one file, keep its temp folder
```

Each `Validate-*.ps1` works in its own folder under the OS temp directory, using a few bytes of placeholder data (`fixtures/source/`) and a fake ExifTool (`fixtures/tools/`). Real ExifTool is not needed and nothing outside the temp folder is touched.

| File | Covers |
| ---- | ------ |
| `Validate-Safety.ps1` | Preview defaults, name collisions, verified deletes, missing / hostile / broken EXIF, interrupted runs (real process kills on both move paths), undo, inventory |
| `Validate-Reorg-Media.ps1` | Sorting by bucket and camera, model map, reruns, `Merge-Model-Folders` |
| `Validate-Placement.ps1` | Mismatch report and fix, `/` vs `\` paths from ExifTool |
| `Validate-Reclassify-MediaTree.ps1` | `Cameras / Phones / Others` regrouping |
| `Validate-RawJpg-Pairs.ps1` | RAW + JPG pairing and review moves |
| `Validate-Raw-Format-Pairs.ps1` | Same shot in two RAW formats |
| `Validate-LivePhoto-Pairs.ps1` | Live Photo pairing |

`PHOTOTRIAGE_FORCE_COPY_MOVE=1` makes moves use the cross-drive copy path on a single drive; the tests use it to cover that path.
