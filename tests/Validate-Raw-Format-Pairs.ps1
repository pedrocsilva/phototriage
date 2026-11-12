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

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "scripts\Find-Raw-Format-Pairs.ps1"
$fakeExifTool = Join-Path $PSScriptRoot "fixtures\tools\fake-exiftool-rawformat.ps1"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("media-rawformat-tests-" + [Guid]::NewGuid().ToString("N"))
$dest = Join-Path $tempRoot "dest"
$rawDir = Join-Path $dest "Cameras\Fujifilm X-T30\RAW"
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null

try {
  Write-Host "Test workspace: $tempRoot"

  Set-Content -LiteralPath (Join-Path $rawDir "same_001.raf") -Value "a"
  Set-Content -LiteralPath (Join-Path $rawDir "same_001.dng") -Value "b"
  Set-Content -LiteralPath (Join-Path $rawDir "solo_001.raf") -Value "c"
  Set-Content -LiteralPath (Join-Path $rawDir "solo_002.dng") -Value "d"

  & pwsh -NoProfile -File $scriptPath `
    -DestRoot $dest `
    -Class Cameras `
    -ExifTool $fakeExifTool

  $summaryPath = Get-ChildItem (Join-Path $dest "_logs\raw_format_pairs_*.summary.json") |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  Assert-PathExists $summaryPath
  $summary = Get-Content -LiteralPath $summaryPath | ConvertFrom-Json

  Assert-True ($summary.modelsScanned -eq 1) "Expected one scanned model."
  Assert-True ($summary.rawSeen -eq 4) "Expected four RAW files seen."
  Assert-True ($summary.candidateGroups -eq 1) "Expected one RAW-format candidate group."
  Assert-True ($summary.candidateFiles -eq 2) "Expected two files in candidate groups."

  $groupsCsv = $summary.groupsCsv
  $membersCsv = $summary.membersCsv
  Assert-PathExists $groupsCsv
  Assert-PathExists $membersCsv

  $groups = Import-Csv -LiteralPath $groupsCsv
  $members = Import-Csv -LiteralPath $membersCsv
  Assert-True (@($groups).Count -eq 1) "Expected exactly one groups row."
  Assert-True (@($members).Count -eq 2) "Expected exactly two member rows."
  Assert-True (($groups[0].Exts -match "dng") -and ($groups[0].Exts -match "raf")) "Expected ext set to contain dng and raf."

  Write-Host ""
  Write-Host "Validate-Raw-Format-Pairs checks passed."
}
finally {
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepTemp) {
    Write-Host "Temp kept at: $tempRoot"
  }
}
