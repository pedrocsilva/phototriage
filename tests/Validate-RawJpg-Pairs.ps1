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
$scriptPath = Join-Path $repoRoot "scripts\Find-RawJpg-Pairs.ps1"
$fakeExifTool = Join-Path $PSScriptRoot "fixtures\tools\fake-exiftool-rawjpg.ps1"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("media-rawjpg-tests-" + [Guid]::NewGuid().ToString("N"))
$dest = Join-Path $tempRoot "dest"
$modelRoot = Join-Path $dest "Cameras\Sony A7 IV"
$rawDir = Join-Path $modelRoot "RAW"
$jpgDir = Join-Path $modelRoot "JPG"

New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
New-Item -ItemType Directory -Path $jpgDir -Force | Out-Null

try {
  Write-Host "Test workspace: $tempRoot"

  # Seed files expected by fake exiftool
  Set-Content -LiteralPath (Join-Path $rawDir "img_0001.arw") -Value "raw-1"
  Set-Content -LiteralPath (Join-Path $rawDir "img_0002.arw") -Value "raw-2"
  Set-Content -LiteralPath (Join-Path $jpgDir "img_0001.jpg") -Value "jpg-1"
  Set-Content -LiteralPath (Join-Path $jpgDir "img_0002.jpg") -Value "jpg-2"
  Set-Content -LiteralPath (Join-Path $jpgDir "img_9999.jpg") -Value "jpg-unmatched"

  # 1) Report
  & pwsh -NoProfile -File $scriptPath `
    -DestRoot $dest `
    -Class Cameras `
    -Action Report `
    -ExifTool $fakeExifTool

  $summaryPath = Get-ChildItem (Join-Path $dest "_logs\raw_jpg_pairs_*.summary.json") |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  Assert-PathExists $summaryPath

  $summary = Get-Content -LiteralPath $summaryPath | ConvertFrom-Json
  Assert-True ($summary.pairs -eq 2) "Expected 2 pairs in report mode."
  Assert-True ($summary.unmatchedJpg -eq 1) "Expected 1 unmatched JPG in report mode."
  Assert-True (-not $summary.exactOnly) "Expected exactOnly=false in default report mode."

  # 1b) Report exact-only should not match near-time candidates
  & pwsh -NoProfile -File $scriptPath `
    -DestRoot $dest `
    -Class Cameras `
    -Action Report `
    -ExactOnly `
    -ExifTool $fakeExifTool

  $summaryExactPath = Get-ChildItem (Join-Path $dest "_logs\raw_jpg_pairs_*.summary.json") |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  Assert-PathExists $summaryExactPath

  $summaryExact = Get-Content -LiteralPath $summaryExactPath | ConvertFrom-Json
  Assert-True ($summaryExact.exactOnly -eq $true) "Expected exactOnly=true in exact-only mode."
  Assert-True ($summaryExact.pairs -le $summary.pairs) "Exact-only mode must not increase pair count."
  Assert-True ($summaryExact.unmatchedJpg -ge $summary.unmatchedJpg) "Exact-only mode must not reduce unmatched JPG count."

  # 2) Move lower-resolution file per matched pair
  & pwsh -NoProfile -File $scriptPath `
    -DestRoot $dest `
    -Class Cameras `
    -Action MoveJpgToReview `
    -ExifTool $fakeExifTool

  Assert-PathExists (Join-Path $modelRoot "_raw_jpg_dupes\JPG\img_0001.jpg")
  Assert-PathExists (Join-Path $modelRoot "_raw_jpg_dupes\RAW\img_0002.arw")
  Assert-PathExists (Join-Path $jpgDir "img_9999.jpg")
  Assert-PathMissing (Join-Path $jpgDir "img_0001.jpg")
  Assert-PathExists (Join-Path $jpgDir "img_0002.jpg")
  Assert-PathMissing (Join-Path $rawDir "img_0002.arw")

  Write-Host ""
  Write-Host "Validate-RawJpg-Pairs checks passed."
}
finally {
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepTemp) {
    Write-Host "Temp kept at: $tempRoot"
  }
}
