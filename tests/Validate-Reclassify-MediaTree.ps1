#Requires -Version 7.4
param(
  [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) {
    throw "ASSERT FAILED: $Message"
  }
}

function Assert-PathExists {
  param([Parameter(Mandatory = $true)][string]$Path)
  Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Expected path to exist: $Path"
}

function Assert-PathMissing {
  param([Parameter(Mandatory = $true)][string]$Path)
  Assert-True -Condition (-not (Test-Path -LiteralPath $Path)) -Message "Expected path to be missing: $Path"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "scripts\Reclassify-MediaTree.ps1"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("media-reclassify-tests-" + [Guid]::NewGuid().ToString("N"))
$dest = Join-Path $tempRoot "dest"

New-Item -ItemType Directory -Path $dest -Force | Out-Null

try {
  Write-Host "Test workspace: $tempRoot"

  # Build a small representative tree in old layout: Bucket\Model\...
  $seedFiles = @(
    @{ Rel = "JPG\Apple iPhone 14 Pro\phone.jpg";            Content = "phone-jpg" },
    @{ Rel = "RAW\Nikon Z6\z6.nef";                          Content = "camera-raw" },
    @{ Rel = "VIDEO\UNKNOWN\clip.mp4";                       Content = "unknown-video" },
    @{ Rel = "ELSE\HTC One\img.png";                         Content = "phone-else" },
    @{ Rel = "JPG\Canon 7D\nested\canon.jpg";                Content = "nested-jpg" },
    @{ Rel = "RAW\Sony A7 IV\collision.jpg";                 Content = "collision-raw" },
    @{ Rel = "JPG\Sony A7 IV\collision.jpg";                 Content = "collision-jpg" }
  )

  foreach ($f in $seedFiles) {
    $full = Join-Path $dest $f.Rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    Set-Content -LiteralPath $full -Value $f.Content
  }

  # 1) Report mode should not move anything
  & pwsh -NoProfile -File $scriptPath `
    -DestRoot $dest `
    -Action Report

  Assert-PathExists (Join-Path $dest "JPG\Apple iPhone 14 Pro\phone.jpg")
  Assert-PathMissing (Join-Path $dest "Phones\Apple iPhone 14 Pro\PHOTO\phone.jpg")

  # 2) Move mode should reclassify structure
  & pwsh -NoProfile -File $scriptPath `
    -DestRoot $dest `
    -Action Move `
    -PruneEmptySourceDirs

  Assert-PathExists (Join-Path $dest "Phones\Apple iPhone 14 Pro\JPG\phone.jpg")
  Assert-PathExists (Join-Path $dest "Cameras\Nikon Z6\RAW\z6.nef")
  Assert-PathExists (Join-Path $dest "Others\UNKNOWN\VIDEO\clip.mp4")
  Assert-PathExists (Join-Path $dest "Phones\HTC One\ELSE\img.png")
  Assert-PathExists (Join-Path $dest "Cameras\Canon 7D\JPG\nested\canon.jpg")

  # RAW/JPG now remain split under each model.
  Assert-PathExists (Join-Path $dest "Cameras\Sony A7 IV\RAW\collision.jpg")
  Assert-PathExists (Join-Path $dest "Cameras\Sony A7 IV\JPG\collision.jpg")

  # Old root buckets should still exist but be empty after prune.
  Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $dest "JPG") -Force | Measure-Object).Count -eq 0) -Message "Expected JPG bucket to be empty after prune."
  Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $dest "RAW") -Force | Measure-Object).Count -eq 0) -Message "Expected RAW bucket to be empty after prune."
  Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $dest "VIDEO") -Force | Measure-Object).Count -eq 0) -Message "Expected VIDEO bucket to be empty after prune."
  Assert-True -Condition ((Get-ChildItem -LiteralPath (Join-Path $dest "ELSE") -Force | Measure-Object).Count -eq 0) -Message "Expected ELSE bucket to be empty after prune."

  Write-Host ""
  Write-Host "Validate-Reclassify-MediaTree checks passed."
}
finally {
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepTemp) {
    Write-Host "Temp kept at: $tempRoot"
  }
}
