#Requires -Version 7.4
param(
  [switch]$KeepTemp
)

# Safety tests for every script that moves or deletes files:
# Reorg-Media, Merge-Model-Folders, Reclassify-MediaTree, Prune-Duplicate-Groups
# (plus Find-Duplicates, which feeds Prune).
#
# Covers: preview-by-default, name collisions, interrupted runs (simulated crash
# points and real process kills), and missing / hostile / broken EXIF data.
# The core invariant checked everywhere: no file is ever overwritten or lost.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scripts = @{
  Reorg      = Join-Path $repoRoot "scripts/Reorg-Media.ps1"
  Merge      = Join-Path $repoRoot "scripts/Merge-Model-Folders.ps1"
  Reclassify = Join-Path $repoRoot "scripts/Reclassify-MediaTree.ps1"
  Prune      = Join-Path $repoRoot "scripts/Prune-Duplicate-Groups.ps1"
  FindDupes  = Join-Path $repoRoot "scripts/Find-Duplicates.ps1"
  Undo     = Join-Path $repoRoot "scripts/Undo-Moves.ps1"
  Inventory = Join-Path $repoRoot "scripts/Get-MediaInventory.ps1"
}
$tools = Join-Path $PSScriptRoot "fixtures/tools"
$fakeExif      = Join-Path $tools "fake-exiftool.ps1"
$fakeExifPosix = Join-Path $tools "fake-exiftool-posix.ps1"
$fakeExifEdge  = Join-Path $tools "fake-exiftool-edge.ps1"
$fakeExifBad   = Join-Path $tools "fake-exiftool-badjson.ps1"
$pwshExe = (Get-Process -Id $PID).Path

Import-Module (Join-Path $repoRoot "modules/PhotoTriage.psm1") -Force -DisableNameChecking

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("media-safety-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$script:passed = 0

# ---------------------------------------------------------------- helpers

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}
function Assert-Exists([string]$Path) {
  Assert-True (Test-Path -LiteralPath $Path) "Expected path to exist: $Path"
}
function Assert-Missing([string]$Path) {
  Assert-True (-not (Test-Path -LiteralPath $Path)) "Expected path to be missing: $Path"
}
function Assert-Content([string]$Path, [string]$Expected) {
  Assert-Exists $Path
  $actual = (Get-Content -LiteralPath $Path -Raw).Trim()
  Assert-True ($actual -eq $Expected) "Content of $Path is '$actual', expected '$Expected'"
}

function Test-Case([string]$Name, [scriptblock]$Body) {
  & $Body
  $script:passed++
  Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
}

# Runs a repo script in a child pwsh; returns the exit code. Output goes to a log.
function Invoke-Repo([string]$Script, [string[]]$Arguments) {
  $log = Join-Path $tempRoot ("run-" + [Guid]::NewGuid().ToString("N") + ".log")
  & $pwshExe -NoProfile -File $Script @Arguments *> $log
  return $LASTEXITCODE
}

function New-Workspace([string]$Name) {
  $ws = Join-Path $tempRoot $Name
  New-Item -ItemType Directory -Path $ws -Force | Out-Null
  return $ws
}

function New-File([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -LiteralPath $Path -Value $Content -NoNewline
}

function Get-MediaFiles([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '[\\/]_logs[\\/]' -and $_.Name -notlike '*.phototriage-partial' })
}

# Every expected content string must appear exactly once across $Roots, and
# nothing else may appear (no lost files, no duplicated files).
# -AllowDuplicates N: up to N files may exist twice (never more, never lost). Used for
# the cross-drive copy path, where a kill between "rename copy" and "delete original"
# leaves the in-flight file in both places.
function Assert-ContentConserved([string[]]$Roots, [string[]]$ExpectedContents, [int]$AllowDuplicates = 0) {
  $seen = @{}
  foreach ($r in $Roots) {
    foreach ($f in (Get-MediaFiles $r)) {
      $c = Get-Content -LiteralPath $f.FullName -Raw
      if ($seen.ContainsKey($c)) { $seen[$c]++ } else { $seen[$c] = 1 }
    }
  }
  $dupes = 0
  foreach ($e in $ExpectedContents) {
    Assert-True ($seen.ContainsKey($e)) "File with content '$e' was lost"
    if ($seen[$e] -eq 2 -and $dupes -lt $AllowDuplicates) { $dupes++; continue }
    Assert-True ($seen[$e] -eq 1) "File with content '$e' exists $($seen[$e]) times"
  }
  Assert-True ($seen.Count -eq $ExpectedContents.Count) "Found $($seen.Count) distinct files, expected $($ExpectedContents.Count)"
}

# Starts a script in the background, kills it (SIGKILL / TerminateProcess) once
# $Probe reports at least $KillAfter, and returns how far it had got.
function Invoke-AndKill([string]$Script, [string[]]$Arguments, [scriptblock]$Probe, [int]$KillAfter) {
  $quoted = @("-NoProfile", "-File", "`"$Script`"") + ($Arguments | ForEach-Object { if ($_ -like '-*') { $_ } else { "`"$_`"" } })
  $out = Join-Path $tempRoot ("bg-" + [Guid]::NewGuid().ToString("N") + ".log")
  $proc = Start-Process -FilePath $pwshExe -ArgumentList $quoted -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
  $deadline = (Get-Date).AddSeconds(120)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    if ((& $Probe) -ge $KillAfter) {
      Stop-Process -Id $proc.Id -Force
      $proc.WaitForExit()
      return [pscustomobject]@{ Killed = $true; Progress = (& $Probe) }
    }
    Start-Sleep -Milliseconds 20
  }
  return [pscustomobject]@{ Killed = $false; Progress = (& $Probe) }
}

try {
  Write-Host "Test workspace: $tempRoot"
  Write-Host "PowerShell $($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
  Write-Host ""

  # ============================================================ 1. Preview is the default

  Test-Case "Reorg-Media: default run is a preview (no moves, no folders)" {
    $ws = New-Workspace "default-reorg"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    New-File (Join-Path $src "camera/img1.jpg") "img1"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif)
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $src "camera/img1.jpg") "img1"
    Assert-Missing (Join-Path $dst "JPG")
  }

  Test-Case "Merge-Model-Folders: default run is a preview" {
    $ws = New-Workspace "default-merge"
    New-File (Join-Path $ws "JPG/iPhone 14 Pro/a.jpg") "a"
    $rc = Invoke-Repo $scripts.Merge @("-DestRoot", $ws, "-Stage", "JPG")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $ws "JPG/iPhone 14 Pro/a.jpg") "a"
    Assert-Missing (Join-Path $ws "JPG/Apple iPhone 14 Pro")
  }

  Test-Case "Reclassify-MediaTree: default run is a preview" {
    $ws = New-Workspace "default-reclassify"
    New-File (Join-Path $ws "RAW/Sony A7 IV/a.arw") "a"
    $rc = Invoke-Repo $scripts.Reclassify @("-DestRoot", $ws)
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $ws "RAW/Sony A7 IV/a.arw") "a"
    Assert-Missing (Join-Path $ws "Cameras")
  }

  Test-Case "Prune-Duplicate-Groups: default run and -WhatIf delete nothing" {
    $ws = New-Workspace "default-prune"
    $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes("same"))) -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant()
    $g = Join-Path $ws "JPG/Cam/${hash}_2"
    New-File (Join-Path $g "001_a.jpg") "same"
    New-File (Join-Path $g "002_a.jpg") "same"
    $rc = Invoke-Repo $scripts.Prune @("-DuplicatesRoot", $ws)
    Assert-True ($rc -eq 0) "exit code $rc"
    $rc = Invoke-Repo $scripts.Prune @("-DuplicatesRoot", $ws, "-Action", "Delete", "-WhatIf")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Exists (Join-Path $g "001_a.jpg")
    Assert-Exists (Join-Path $g "002_a.jpg")
  }

  # ============================================================ 2. Collisions

  Test-Case "Reorg-Media: never overwrites existing files in the destination" {
    $ws = New-Workspace "collide-reorg"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    $model = Join-Path $dst "JPG/Apple iPhone 15 Pro Max"
    New-File (Join-Path $src "camera/img1.jpg") "incoming"
    New-File (Join-Path $model "img1.jpg") "existing-0"
    New-File (Join-Path $model "img1__1.jpg") "existing-1"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $model "img1.jpg") "existing-0"
    Assert-Content (Join-Path $model "img1__1.jpg") "existing-1"
    Assert-Content (Join-Path $model "img1__2.jpg") "incoming"
    Assert-Missing (Join-Path $src "camera/img1.jpg")
  }

  Test-Case "Reorg-Media: preview shows distinct targets for same-name files" {
    $ws = New-Workspace "collide-preview"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    New-File (Join-Path $src "a/duplicate.jpg") "a"
    New-File (Join-Path $src "b/duplicate.jpg") "b"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif)
    Assert-True ($rc -eq 0) "exit code $rc"
    $plan = @(Get-ChildItem -LiteralPath (Join-Path $dst "_logs") -Filter "reorg_*.log" | Get-Content | Where-Object { $_ -like "PLAN*" })
    $targets = @($plan | ForEach-Object { ($_ -split "`t")[3] } | Sort-Object -Unique)
    Assert-True ($plan.Count -eq 2) "expected 2 planned moves, got $($plan.Count)"
    Assert-True ($targets.Count -eq 2) "preview planned the same target twice: $($targets -join ', ')"
  }

  Test-Case "Merge-Model-Folders: same-name files keep both contents" {
    $ws = New-Workspace "collide-merge"
    New-File (Join-Path $ws "JPG/iPhone 14 Pro/same.jpg") "legacy"
    New-File (Join-Path $ws "JPG/iPhone 14 Pro/sub/same.jpg") "legacy-sub"
    New-File (Join-Path $ws "JPG/Apple iPhone 14 Pro/same.jpg") "canonical"
    $rc = Invoke-Repo $scripts.Merge @("-DestRoot", $ws, "-Stage", "JPG", "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $ws "JPG/Apple iPhone 14 Pro/same.jpg") "canonical"
    Assert-ContentConserved @((Join-Path $ws "JPG")) @("legacy", "legacy-sub", "canonical")
    Assert-Missing (Join-Path $ws "JPG/iPhone 14 Pro")
  }

  Test-Case "Reclassify-MediaTree: existing target is never overwritten" {
    $ws = New-Workspace "collide-reclassify"
    New-File (Join-Path $ws "RAW/Sony A7 IV/a.arw") "incoming"
    New-File (Join-Path $ws "Cameras/Sony A7 IV/RAW/a.arw") "existing"
    $rc = Invoke-Repo $scripts.Reclassify @("-DestRoot", $ws, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $ws "Cameras/Sony A7 IV/RAW/a.arw") "existing"
    Assert-Content (Join-Path $ws "Cameras/Sony A7 IV/RAW/a__1.arw") "incoming"
  }

  Test-Case "Move-MediaFile: refuses to overwrite (rename and copy paths)" {
    $ws = New-Workspace "collide-helper"
    foreach ($forceCopy in @("0", "1")) {
      $a = Join-Path $ws "a-$forceCopy.jpg"; $b = Join-Path $ws "b-$forceCopy.jpg"
      New-File $a "source"; New-File $b "target"
      $env:PHOTOTRIAGE_FORCE_COPY_MOVE = $forceCopy
      $threw = $false
      try { Move-MediaFile -Source $a -Target $b } catch { $threw = $true }
      Remove-Item Env:PHOTOTRIAGE_FORCE_COPY_MOVE
      Assert-True $threw "Move-MediaFile did not refuse an existing target (forceCopy=$forceCopy)"
      Assert-Content $a "source"
      Assert-Content $b "target"
    }
  }

  Test-Case "Get-UniqueTargetPath: case-only clashes get a new name" {
    $reserved = New-ReservedPathSet
    $dir = New-Workspace "case-clash"
    $first = Get-UniqueTargetPath -targetPath (Join-Path $dir "IMG_0001.JPG") -Reserved $reserved
    $second = Get-UniqueTargetPath -targetPath (Join-Path $dir "img_0001.jpg") -Reserved $reserved
    Assert-True ($first -ne $second -and $second -like "*__1*") "case-only clash not separated: $first / $second"
  }

  # ============================================================ 3. Prune only deletes true duplicates

  Test-Case "Prune-Duplicate-Groups: keeps a non-identical file placed in a group" {
    $ws = New-Workspace "prune-mismatch"
    $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes("same"))) -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant()
    $g = Join-Path $ws "JPG/Cam/${hash}_3"
    New-File (Join-Path $g "001_a.jpg") "same"
    New-File (Join-Path $g "002_a.jpg") "same"
    New-File (Join-Path $g "003_a.jpg") "DIFFERENT"
    $rc = Invoke-Repo $scripts.Prune @("-DuplicatesRoot", $ws, "-Action", "Delete")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $g "001_a.jpg") "same"
    Assert-Missing (Join-Path $g "002_a.jpg")
    Assert-Content (Join-Path $g "003_a.jpg") "DIFFERENT"
  }

  Test-Case "Prune-Duplicate-Groups: ignores folders that are not duplicate groups" {
    $ws = New-Workspace "prune-notgroup"
    $g = Join-Path $ws "JPG/Cam/2019 Holidays"
    New-File (Join-Path $g "a.jpg") "same"
    New-File (Join-Path $g "b.jpg") "same"
    $rc = Invoke-Repo $scripts.Prune @("-DuplicatesRoot", $ws, "-Action", "Delete")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Exists (Join-Path $g "a.jpg")
    Assert-Exists (Join-Path $g "b.jpg")
  }

  Test-Case "Prune-Duplicate-Groups: leaves a group alone if its contents changed" {
    $ws = New-Workspace "prune-changed"
    $g = Join-Path $ws "JPG/Cam/000000000000_2"   # hash prefix that matches nothing
    New-File (Join-Path $g "001_a.jpg") "same"
    New-File (Join-Path $g "002_a.jpg") "same"
    $rc = Invoke-Repo $scripts.Prune @("-DuplicatesRoot", $ws, "-Action", "Delete")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Exists (Join-Path $g "001_a.jpg")
    Assert-Exists (Join-Path $g "002_a.jpg")
  }

  Test-Case "Find-Duplicates -> Prune end to end: exactly one copy of each file survives" {
    $ws = New-Workspace "dupes-e2e"
    $dst = Join-Path $ws "dst"; $dup = Join-Path $ws "dupes"
    New-File (Join-Path $dst "JPG/Cam/x.jpg") "photo-x"
    New-File (Join-Path $dst "JPG/Cam/x-copy.jpg") "photo-x"
    New-File (Join-Path $dst "JPG/Cam/x-copy2.jpg") "photo-x"
    New-File (Join-Path $dst "JPG/Cam/y.jpg") "photo-y"
    New-File (Join-Path $dst "JPG/Cam/z.jpg") "photo-z"   # same size as y, different bytes
    $rc = Invoke-Repo $scripts.FindDupes @("-DestRoot", $dst, "-DuplicatesRoot", $dup, "-Action", "MoveGroups")
    Assert-True ($rc -eq 0) "find exit code $rc"
    $rc = Invoke-Repo $scripts.Prune @("-DuplicatesRoot", $dup, "-Action", "Delete")
    Assert-True ($rc -eq 0) "prune exit code $rc"
    Assert-ContentConserved @($dst, $dup) @("photo-x", "photo-y", "photo-z")
  }

  # ============================================================ 4. Missing / hostile / broken EXIF

  Test-Case "Reorg-Media: missing or hostile EXIF models stay inside their bucket" {
    $ws = New-Workspace "exif-edge"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    $names = @("dotdot.jpg", "dot.jpg", "traversal.jpg", "backslash.jpg", "blank.jpg", "reserved.jpg", "trailingdot.jpg", "emptystr.jpg", "nometa.jpg")
    foreach ($n in $names) { New-File (Join-Path $src $n) "c-$n" }
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExifEdge, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    $jpgRoot = Join-Path $dst "JPG"
    foreach ($n in $names) {
      $hit = @(Get-ChildItem -LiteralPath $jpgRoot -Recurse -File -Force -Filter $n)
      Assert-True ($hit.Count -eq 1) "$n not found exactly once under JPG/"
      # Must be exactly JPG/<one folder>/<file>: no escaping, no landing in JPG/ itself.
      $parent = $hit[0].Directory
      Assert-True ($parent.Parent.FullName -eq (Get-Item -LiteralPath $jpgRoot).FullName) "$n landed in $($parent.FullName)"
      Assert-True (-not $parent.Name.StartsWith(".") -and $parent.Name -notmatch '[/\\]') "unsafe or hidden folder name '$($parent.Name)'"
    }
    Assert-Exists (Join-Path $jpgRoot "UNKNOWN/nometa.jpg")
    Assert-Exists (Join-Path $jpgRoot "UNKNOWN/blank.jpg")
    Assert-Exists (Join-Path $jpgRoot "_NUL/reserved.jpg")
    Assert-Exists (Join-Path $jpgRoot "Canon EOS/trailingdot.jpg")
    Assert-ContentConserved @($dst) ($names | ForEach-Object { "c-$_" })
  }

  Test-Case "Reorg-Media: ExifTool not installed -> exit 2, nothing moved" {
    $ws = New-Workspace "exif-missing"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    New-File (Join-Path $src "img1.jpg") "img1"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", "definitely-not-exiftool-xyz", "-Action", "Move")
    Assert-True ($rc -eq 2) "expected exit code 2, got $rc"
    Assert-Content (Join-Path $src "img1.jpg") "img1"
  }

  Test-Case "Reorg-Media: broken ExifTool JSON -> exit 1, nothing moved" {
    $ws = New-Workspace "exif-badjson"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    New-File (Join-Path $src "img1.jpg") "img1"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExifBad, "-Action", "Move")
    Assert-True ($rc -eq 1) "expected exit code 1, got $rc"
    Assert-Content (Join-Path $src "img1.jpg") "img1"
    Assert-Missing (Join-Path $dst "JPG")
  }

  Test-Case "Reorg-Media: destination inside source is skipped, also with '/' paths from ExifTool" {
    $ws = New-Workspace "dest-in-source"
    $src = Join-Path $ws "photos"; $dst = Join-Path $src "_sorted"
    New-File (Join-Path $src "camera/img1.jpg") "img1"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExifPosix, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExifPosix, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $dst "JPG/Apple iPhone 15 Pro Max/img1.jpg") "img1"
    Assert-Missing (Join-Path $dst "JPG/Apple iPhone 15 Pro Max/img1__1.jpg")
  }

  # ============================================================ 5. Interrupted runs

  Test-Case "Reorg-Media: rerunning a finished run changes nothing" {
    $ws = New-Workspace "rerun-noop"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    New-File (Join-Path $src "camera/img1.jpg") "img1"
    New-File (Join-Path $src "raw/raw1.arw") "raw1"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-ContentConserved @($src, $dst) @("img1", "raw1")
    Assert-Missing (Join-Path $dst "JPG/Apple iPhone 15 Pro Max/img1__1.jpg")
  }

  Test-Case "Move-MediaFile copy path: content and timestamp kept, source removed" {
    $ws = New-Workspace "copy-path"
    $a = Join-Path $ws "src/a.jpg"; $b = Join-Path $ws "dst/a.jpg"
    New-File $a "payload"
    (Get-Item -LiteralPath $a).LastWriteTimeUtc = [datetime]::new(2019, 5, 26, 18, 4, 33, [DateTimeKind]::Utc)
    New-Item -ItemType Directory -Path (Split-Path -Parent $b) | Out-Null
    $env:PHOTOTRIAGE_FORCE_COPY_MOVE = "1"
    try { Move-MediaFile -Source $a -Target $b } finally { Remove-Item Env:PHOTOTRIAGE_FORCE_COPY_MOVE }
    Assert-Missing $a
    Assert-Content $b "payload"
    Assert-True ((Get-Item -LiteralPath $b).LastWriteTimeUtc -eq [datetime]::new(2019, 5, 26, 18, 4, 33, [DateTimeKind]::Utc)) "timestamp not preserved"
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $b) -Filter "*.phototriage-partial").Count -eq 0) "partial file left behind"
  }

  Test-Case "Reorg-Media: leftover partial copy from a crash never takes the real name" {
    $ws = New-Workspace "crash-partial"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    $model = Join-Path $dst "JPG/Apple iPhone 15 Pro Max"
    New-File (Join-Path $src "camera/img1.jpg") "img1-full"
    New-File (Join-Path $model "img1.jpg.phototriage-partial") "img1-ha"   # simulated half-written copy
    $env:PHOTOTRIAGE_FORCE_COPY_MOVE = "1"
    try {
      $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move")
    } finally { Remove-Item Env:PHOTOTRIAGE_FORCE_COPY_MOVE }
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-Content (Join-Path $model "img1.jpg") "img1-full"
    Assert-Content (Join-Path $model "img1.jpg.phototriage-partial") "img1-ha"
    Assert-Missing (Join-Path $src "camera/img1.jpg")
  }

  # Real interruptions: kill the process mid-run, rerun, check nothing was lost or duplicated.
  $killCount = 1500
  foreach ($mode in @("rename", "copy")) {
    Test-Case "Reorg-Media: killed mid-run ($mode path), rerun completes with no loss or duplicates" {
      $ws = New-Workspace "kill-reorg-$mode"
      $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
      $expected = New-Object System.Collections.Generic.List[string]
      foreach ($i in 1..$killCount) {
        $sub = if ($i % 2) { "a" } else { "b" }          # same names in a/ and b/ -> collisions
        $n = "f{0:0000}.jpg" -f [math]::Ceiling($i / 2)
        New-File (Join-Path $src "$sub/$n") "c-$i"
        $expected.Add("c-$i")
      }
      if ($mode -eq "copy") { $env:PHOTOTRIAGE_FORCE_COPY_MOVE = "1" }
      try {
        $arguments = @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move")
        $probe = { @(Get-MediaFiles (Join-Path $dst "JPG")).Count }
        $r = Invoke-AndKill $scripts.Reorg $arguments $probe 150
        Assert-True $r.Killed "process finished before it could be killed (moved $($r.Progress)); raise the file count"
        Write-Host ("      killed after {0}/{1} files moved" -f $r.Progress, $killCount)
        $rc = Invoke-Repo $scripts.Reorg $arguments
        Assert-True ($rc -eq 0) "rerun exit code $rc"
      } finally { if ($mode -eq "copy") { Remove-Item Env:PHOTOTRIAGE_FORCE_COPY_MOVE } }
      $allowed = if ($mode -eq "copy") { 1 } else { 0 }
      Assert-ContentConserved @($src, $dst) $expected.ToArray() -AllowDuplicates $allowed
      Assert-True (@(Get-MediaFiles $src).Count -eq 0) "files left in source after rerun"
    }
  }

  Test-Case "Reclassify-MediaTree: killed mid-run, rerun completes with no loss or duplicates" {
    $ws = New-Workspace "kill-reclassify"
    $expected = New-Object System.Collections.Generic.List[string]
    foreach ($i in 1..$killCount) {
      New-File (Join-Path $ws ("RAW/Sony A7 IV/{0}/r{1:0000}.arw" -f ($i % 3), [math]::Ceiling($i / 3))) "c-$i"
      $expected.Add("c-$i")
    }
    $arguments = @("-DestRoot", $ws, "-Action", "Move", "-PruneEmptySourceDirs")
    $probe = { @(Get-MediaFiles (Join-Path $ws "Cameras")).Count }
    $r = Invoke-AndKill $scripts.Reclassify $arguments $probe 150
    Assert-True $r.Killed "process finished before it could be killed (moved $($r.Progress)); raise the file count"
    Write-Host ("      killed after {0}/{1} files moved" -f $r.Progress, $killCount)
    $rc = Invoke-Repo $scripts.Reclassify $arguments
    Assert-True ($rc -eq 0) "rerun exit code $rc"
    Assert-ContentConserved @($ws) $expected.ToArray()
    Assert-True (@(Get-MediaFiles (Join-Path $ws "RAW")).Count -eq 0) "files left in RAW/ after rerun"
  }

  Test-Case "Merge-Model-Folders: killed mid-run, rerun completes with no loss or duplicates" {
    $ws = New-Workspace "kill-merge"
    $expected = New-Object System.Collections.Generic.List[string]
    foreach ($i in 1..$killCount) {
      New-File (Join-Path $ws ("JPG/iPhone 14 Pro/m{0:0000}.jpg" -f $i)) "c-$i"
      $expected.Add("c-$i")
    }
    $arguments = @("-DestRoot", $ws, "-Stage", "JPG", "-Action", "Move")
    $probe = { @(Get-MediaFiles (Join-Path $ws "JPG/Apple iPhone 14 Pro")).Count }
    $r = Invoke-AndKill $scripts.Merge $arguments $probe 150
    Assert-True $r.Killed "process finished before it could be killed (moved $($r.Progress)); raise the file count"
    Write-Host ("      killed after {0}/{1} files moved" -f $r.Progress, $killCount)
    $rc = Invoke-Repo $scripts.Merge $arguments
    Assert-True ($rc -eq 0) "rerun exit code $rc"
    Assert-ContentConserved @($ws) $expected.ToArray()
    Assert-Missing (Join-Path $ws "JPG/iPhone 14 Pro")
  }

  # ============================================================ 6. Merge cleanup never deletes files

  Test-Case "Merge-Model-Folders: hidden files are moved, never deleted with the folder" {
    $ws = New-Workspace "merge-hidden"
    $legacy = Join-Path $ws "JPG/iPhone 14 Pro"
    New-File (Join-Path $legacy ".hidden-only.jpg") "hidden"
    if ($IsWindows) {
      $f = Get-Item -LiteralPath (Join-Path $legacy ".hidden-only.jpg") -Force
      $f.Attributes = $f.Attributes -bor [IO.FileAttributes]::Hidden
    }
    $rc = Invoke-Repo $scripts.Merge @("-DestRoot", $ws, "-Stage", "JPG", "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    Assert-ContentConserved @($ws) @("hidden")
  }


  # ============================================================ 7. Undo

  # Snapshot of relative path -> content, to compare trees before/after.
  function Get-TreeSnapshot([string]$Root) {
    $map = [ordered]@{}
    foreach ($f in (Get-MediaFiles $Root | Sort-Object FullName)) {
      $map[$f.FullName.Substring($Root.Length)] = Get-Content -LiteralPath $f.FullName -Raw
    }
    return ($map.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
  }

  Test-Case "Undo-Moves: Reorg + Merge + Reclassify undone in reverse restore the exact original tree" {
    $ws = New-Workspace "undo-chain"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    New-File (Join-Path $src "camera/img1.jpg") "img1"
    New-File (Join-Path $src "raw/raw1.arw") "raw1"
    New-File (Join-Path $src "a/duplicate.jpg") "dup-a"
    New-File (Join-Path $src "b/duplicate.jpg") "dup-b"
    New-File (Join-Path $src "legacy/old.jpg") "old"
    $before = Get-TreeSnapshot $src
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move")
    Assert-True ($rc -eq 0) "reorg exit code $rc"
    # simulate a legacy alias folder so Merge has work to do
    Move-Item -LiteralPath (Join-Path $dst "JPG/UNKNOWN") -Destination (Join-Path $dst "JPG/iPhone 14 Pro")
    $rc = Invoke-Repo $scripts.Merge @("-DestRoot", $dst, "-Action", "Move")
    Assert-True ($rc -eq 0) "merge exit code $rc"
    Move-Item -LiteralPath (Join-Path $dst "JPG/Apple iPhone 14 Pro") -Destination (Join-Path $dst "JPG/UNKNOWN")
    $rc = Invoke-Repo $scripts.Reclassify @("-DestRoot", $dst, "-Action", "Move")
    Assert-True ($rc -eq 0) "reclassify exit code $rc"
    Assert-True (@(Get-MediaFiles $src).Count -eq 0) "source should be empty after reorg"

    $logs = Join-Path $dst "_logs"
    $reorgLog = @(Get-ChildItem -LiteralPath $logs -Filter "reorg_*.log")[0].FullName
    $mergeLog = @(Get-ChildItem -LiteralPath $logs -Filter "merge_models_*.log")[0].FullName
    $reclassLog = @(Get-ChildItem -LiteralPath $logs -Filter "reclassify_tree_*.log")[0].FullName

    # Preview (default) moves nothing.
    $rc = Invoke-Repo $scripts.Undo @("-Log", $reclassLog)
    Assert-True ($rc -eq 0) "undo preview exit code $rc"
    Assert-True (@(Get-MediaFiles $src).Count -eq 0) "undo preview moved files"

    # Undo newest run first; the two folder renames above are test setup, undone by hand.
    $rc = Invoke-Repo $scripts.Undo @("-Log", $reclassLog, "-Action", "Move"); Assert-True ($rc -eq 0) "undo reclassify exit code $rc"
    Move-Item -LiteralPath (Join-Path $dst "JPG/UNKNOWN") -Destination (Join-Path $dst "JPG/Apple iPhone 14 Pro")
    $rc = Invoke-Repo $scripts.Undo @("-Log", $mergeLog, "-Action", "Move"); Assert-True ($rc -eq 0) "undo merge exit code $rc"
    Move-Item -LiteralPath (Join-Path $dst "JPG/iPhone 14 Pro") -Destination (Join-Path $dst "JPG/UNKNOWN")
    $rc = Invoke-Repo $scripts.Undo @("-Log", $reorgLog, "-Action", "Move"); Assert-True ($rc -eq 0) "undo reorg exit code $rc"

    $after = Get-TreeSnapshot $src
    Assert-True ($after -eq $before) "tree after undo differs:`n$after`n--- expected ---`n$before"
  }

  Test-Case "Undo-Moves: never overwrites a file that now occupies the original path" {
    $ws = New-Workspace "undo-occupied"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    New-File (Join-Path $src "camera/img1.jpg") "original"
    $rc = Invoke-Repo $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move")
    Assert-True ($rc -eq 0) "exit code $rc"
    New-File (Join-Path $src "camera/img1.jpg") "newcomer"
    $log = @(Get-ChildItem -LiteralPath (Join-Path $dst "_logs") -Filter "reorg_*.log")[0].FullName
    $rc = Invoke-Repo $scripts.Undo @("-Log", $log, "-Action", "Move")
    Assert-True ($rc -eq 0) "undo exit code $rc"
    Assert-Content (Join-Path $src "camera/img1.jpg") "newcomer"
    Assert-Content (Join-Path $dst "JPG/Apple iPhone 15 Pro Max/img1.jpg") "original"
  }

  Test-Case "Undo-Moves: undoing a killed Reorg run puts every logged file back" {
    $ws = New-Workspace "undo-killed"
    $src = Join-Path $ws "src"; $dst = Join-Path $ws "dst"
    $expected = New-Object System.Collections.Generic.List[string]
    foreach ($i in 1..$killCount) { New-File (Join-Path $src ("k/f{0:0000}.jpg" -f $i)) "c-$i"; $expected.Add("c-$i") }
    $probe = { @(Get-MediaFiles (Join-Path $dst "JPG")).Count }
    $r = Invoke-AndKill $scripts.Reorg @("-Source", $src, "-DestRoot", $dst, "-ExifTool", $fakeExif, "-Action", "Move") $probe 150
    Assert-True $r.Killed "process finished before it could be killed"
    $log = @(Get-ChildItem -LiteralPath (Join-Path $dst "_logs") -Filter "reorg_*.log")[0].FullName
    $logged = @([IO.File]::ReadAllLines($log) | Where-Object { $_.StartsWith("MOVE_DONE") }).Count
    $rc = Invoke-Repo $scripts.Undo @("-Log", $log, "-Action", "Move")
    Assert-True ($rc -eq 0) "undo exit code $rc"
    $left = @(Get-MediaFiles (Join-Path $dst "JPG")).Count
    Write-Host ("      killed after {0} moves, {1} logged, {2} left in dest after undo" -f $r.Progress, $logged, $left)
    # At most the single move in flight at the kill can be missing from the log.
    Assert-True ($left -le 1) "$left files were not restored"
    Assert-ContentConserved @($src, $dst) $expected.ToArray()
  }

  # ============================================================ 8. Misc

  if (-not $IsWindows) {
    Test-Case "Find-Duplicates: unreadable files are never grouped as duplicates" {
      $ws = New-Workspace "dupes-unreadable"
      $dst = Join-Path $ws "dst"; $dup = Join-Path $ws "dupes"
      New-File (Join-Path $dst "JPG/Cam/p.jpg") "aaaa"
      New-File (Join-Path $dst "JPG/Cam/q.jpg") "bbbb"   # same size, different content
      foreach ($n in "p.jpg", "q.jpg") { & chmod 000 (Join-Path $dst "JPG/Cam/$n") }
      try {
        $rc = Invoke-Repo $scripts.FindDupes @("-DestRoot", $dst, "-DuplicatesRoot", $dup, "-Action", "MoveGroups")
      } finally { foreach ($n in "p.jpg", "q.jpg") { & chmod 644 (Join-Path $dst "JPG/Cam/$n") } }
      Assert-True ($rc -eq 0) "exit code $rc"
      Assert-Content (Join-Path $dst "JPG/Cam/p.jpg") "aaaa"
      Assert-Content (Join-Path $dst "JPG/Cam/q.jpg") "bbbb"
    }
  }

  Test-Case "Get-MediaInventory: counts files per extension, read only" {
    $ws = New-Workspace "inventory"
    New-File (Join-Path $ws "a/x.JPG") "1"; New-File (Join-Path $ws "b/y.jpg") "2"; New-File (Join-Path $ws "z.xmp") "3"
    $out = & $pwshExe -NoProfile -File $scripts.Inventory -Path $ws *>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "exit code $LASTEXITCODE"
    Assert-True ($out -match '\.jpg\s+2\s') "jpg count missing:`n$out"
    Assert-True ($out -match 'Total: 3 files') "total missing:`n$out"
    Assert-True (@(Get-MediaFiles $ws).Count -eq 3) "inventory changed files"
  }

  Write-Host ""
  Write-Host "Validate-Safety: all $script:passed checks passed."
}
catch {
  Write-Host ""
  Write-Host "Validate-Safety: FAILED after $script:passed passing checks." -ForegroundColor Red
  throw
}
finally {
  Remove-Item Env:PHOTOTRIAGE_FORCE_COPY_MOVE -ErrorAction SilentlyContinue
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepTemp) {
    Write-Host "Temp kept at: $tempRoot"
  }
}
