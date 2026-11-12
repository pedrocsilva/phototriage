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
$reorgScript = Join-Path $repoRoot "scripts\Reorg-Media.ps1"
$mergeScript = Join-Path $repoRoot "scripts\Merge-Model-Folders.ps1"
$fixtureSource = Join-Path $PSScriptRoot "fixtures\source"
$fakeExifTool = Join-Path $PSScriptRoot "fixtures\tools\fake-exiftool.ps1"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("phototriage-reorg-tests-" + [Guid]::NewGuid().ToString("N"))
$source = Join-Path $tempRoot "source"
$dest = Join-Path $tempRoot "dest"

New-Item -ItemType Directory -Path $source -Force | Out-Null
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -Path (Join-Path $fixtureSource "*") -Destination $source -Recurse -Force

try {
  Write-Host "Test workspace: $tempRoot"

  # 1) WhatIf should not move files.
  & pwsh -NoProfile -File $reorgScript `
    -Source $source `
    -DestRoot $dest `
    -Stage ALL `
    -ExifTool $fakeExifTool `
    -WhatIf

  Assert-PathExists (Join-Path $source "camera\img1.jpg")
  Assert-PathMissing (Join-Path $dest "JPG\Apple iPhone 15 Pro Max\img1.jpg")

  # 2) Real run should move by bucket and model.
  & pwsh -NoProfile -File $reorgScript `
    -Source $source `
    -DestRoot $dest `
    -Stage ALL `
    -ExifTool $fakeExifTool `
    -Action Move

  Assert-PathExists (Join-Path $dest "JPG\Apple iPhone 15 Pro Max\img1.jpg")
  Assert-PathExists (Join-Path $dest "RAW\Sony A7 IV\raw1.arw")
  Assert-PathExists (Join-Path $dest "VIDEO\Google Nexus 5\clip1.mp4")
  Assert-PathExists (Join-Path $dest "ELSE\UNKNOWN\scan1.png")

  # 3) Collision safety: two files with same name must not overwrite.
  $collisionA = Join-Path $dest "JPG\Apple iPhone 15 Pro Max\duplicate.jpg"
  $collisionB = Join-Path $dest "JPG\Apple iPhone 15 Pro Max\duplicate__1.jpg"
  Assert-PathExists $collisionA
  Assert-PathExists $collisionB

  # 4) Unknown extension should remain in source.
  Assert-PathExists (Join-Path $source "misc\ignore.xyz")

  # 5) Rerun should be a no-op for already moved items.
  & pwsh -NoProfile -File $reorgScript `
    -Source $source `
    -DestRoot $dest `
    -Stage ALL `
    -ExifTool $fakeExifTool `
    -Action Move

  # Existing target remains; no regression from rerun.
  Assert-PathExists $collisionA
  Assert-PathExists $collisionB

  # 6) Merge script should consolidate legacy alias folders within a bucket.
  $legacyIphoneDir = Join-Path $dest "JPG\iPhone 14 Pro"
  $canonicalIphoneDir = Join-Path $dest "JPG\Apple iPhone 14 Pro"
  $legacyCanonDir = Join-Path $dest "JPG\Canon EOS 7D"
  $canonicalCanonDir = Join-Path $dest "JPG\Canon 7D"

  New-Item -ItemType Directory -Path $legacyIphoneDir -Force | Out-Null
  New-Item -ItemType Directory -Path $canonicalIphoneDir -Force | Out-Null
  New-Item -ItemType Directory -Path $legacyCanonDir -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $legacyIphoneDir "legacy.jpg") -Value "legacy-iphone"
  Set-Content -LiteralPath (Join-Path $legacyIphoneDir "same-name.jpg") -Value "legacy-collision"
  Set-Content -LiteralPath (Join-Path $canonicalIphoneDir "same-name.jpg") -Value "canonical-collision"
  Set-Content -LiteralPath (Join-Path $legacyCanonDir "canon.jpg") -Value "legacy-canon"

  & pwsh -NoProfile -File $mergeScript `
    -DestRoot $dest `
    -Stage JPG `
    -WhatIf

  Assert-PathExists (Join-Path $legacyIphoneDir "legacy.jpg")
  Assert-PathExists (Join-Path $legacyCanonDir "canon.jpg")

  & pwsh -NoProfile -File $mergeScript `
    -DestRoot $dest `
    -Stage JPG `
    -Action Move

  Assert-PathMissing $legacyIphoneDir
  Assert-PathMissing $legacyCanonDir
  Assert-PathExists (Join-Path $canonicalIphoneDir "legacy.jpg")
  Assert-PathExists (Join-Path $canonicalIphoneDir "same-name.jpg")
  Assert-PathExists (Join-Path $canonicalIphoneDir "same-name__1.jpg")
  Assert-PathExists (Join-Path $canonicalCanonDir "canon.jpg")

  Write-Host ""
  Write-Host "All validation checks passed."
}
finally {
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepTemp) {
    Write-Host "Temp kept at: $tempRoot"
  }
}
