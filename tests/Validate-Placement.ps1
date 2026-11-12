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

function Get-LatestSummary {
  param(
    [Parameter(Mandatory = $true)][string]$Folder,
    [Parameter(Mandatory = $true)][string]$Pattern
  )
  return Get-ChildItem -LiteralPath $Folder -Filter $Pattern |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$reorgScript = Join-Path $repoRoot "scripts\Reorg-Media.ps1"
$validateScript = Join-Path $repoRoot "scripts\Validate-Placement.ps1"
$fixtureSource = Join-Path $PSScriptRoot "fixtures\source"
$fakeExifTool = Join-Path $PSScriptRoot "fixtures\tools\fake-exiftool.ps1"
$fakeExifToolPosix = Join-Path $PSScriptRoot "fixtures\tools\fake-exiftool-posix.ps1"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("media-placement-tests-" + [Guid]::NewGuid().ToString("N"))
$source = Join-Path $tempRoot "source"
$dest = Join-Path $tempRoot "dest"

New-Item -ItemType Directory -Path $source -Force | Out-Null
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -Path (Join-Path $fixtureSource "*") -Destination $source -Recurse -Force

try {
  Write-Host "Test workspace: $tempRoot"

  # Build canonical destination layout first.
  & pwsh -NoProfile -File $reorgScript `
    -Source $source `
    -DestRoot $dest `
    -Stage ALL `
    -ExifTool $fakeExifTool `
    -Action Move

  # Intentionally misplace two files.
  $correctImg = Join-Path $dest "JPG\Apple iPhone 15 Pro Max\img1.jpg"
  $wrongImgDir = Join-Path $dest "JPG\iPhone 15 Pro Max"
  $wrongImg = Join-Path $wrongImgDir "img1.jpg"
  New-Item -ItemType Directory -Path $wrongImgDir -Force | Out-Null
  Move-Item -LiteralPath $correctImg -Destination $wrongImg

  $correctRaw = Join-Path $dest "RAW\Sony A7 IV\raw1.arw"
  $wrongRawDir = Join-Path $dest "JPG\Sony A7 IV"
  $wrongRaw = Join-Path $wrongRawDir "raw1.arw"
  New-Item -ItemType Directory -Path $wrongRawDir -Force | Out-Null
  Move-Item -LiteralPath $correctRaw -Destination $wrongRaw

  # 1) Report mode should find both mismatches without moving files.
  & pwsh -NoProfile -File $validateScript `
    -DestRoot $dest `
    -Stage ALL `
    -ExifTool $fakeExifToolPosix `
    -Action Report

  $logs = Join-Path $dest "_logs"
  $sum1File = Get-LatestSummary -Folder $logs -Pattern "validate_placement_*.summary.json"
  Assert-True -Condition ($null -ne $sum1File) -Message "Expected summary JSON for report run."
  $sum1 = Get-Content -LiteralPath $sum1File.FullName | ConvertFrom-Json

  Assert-True -Condition ($sum1.mismatches -eq 2) -Message "Report should detect 2 mismatches."
  Assert-True -Condition ($sum1.reasonWrongModel -eq 1) -Message "Expected 1 WrongModel mismatch."
  Assert-True -Condition ($sum1.reasonWrongBucket -eq 1) -Message "Expected 1 WrongBucket mismatch."
  Assert-True -Condition ($sum1.moved -eq 0) -Message "Report mode must not move files."
  Assert-PathExists $wrongImg
  Assert-PathExists $wrongRaw

  # 2) Move mode should fix both mismatches.
  & pwsh -NoProfile -File $validateScript `
    -DestRoot $dest `
    -Stage ALL `
    -ExifTool $fakeExifToolPosix `
    -Action MoveMismatches

  $sum2File = Get-LatestSummary -Folder $logs -Pattern "validate_placement_*.summary.json"
  Assert-True -Condition ($null -ne $sum2File) -Message "Expected summary JSON for move run."
  $sum2 = Get-Content -LiteralPath $sum2File.FullName | ConvertFrom-Json

  Assert-True -Condition ($sum2.mismatches -eq 2) -Message "Move run should process the 2 mismatches."
  Assert-True -Condition ($sum2.moved -eq 2) -Message "Move run should move 2 files."
  Assert-True -Condition ($sum2.errors -eq 0) -Message "Move run should have no errors."

  Assert-PathExists $correctImg
  Assert-PathExists $correctRaw
  Assert-PathMissing $wrongImg
  Assert-PathMissing $wrongRaw

  Write-Host ""
  Write-Host "Validate-Placement checks passed."
}
finally {
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepTemp) {
    Write-Host "Temp kept at: $tempRoot"
  }
}
