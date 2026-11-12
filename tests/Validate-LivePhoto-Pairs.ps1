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

function Get-LatestFile {
  param(
    [Parameter(Mandatory = $true)][string]$Folder,
    [Parameter(Mandatory = $true)][string]$Pattern
  )
  return Get-ChildItem -LiteralPath $Folder -Filter $Pattern |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "scripts\Find-LivePhoto-Pairs.ps1"
$fakeExifTool = Join-Path $PSScriptRoot "fixtures\tools\fake-exiftool-livephoto.ps1"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("media-livephoto-tests-" + [Guid]::NewGuid().ToString("N"))
$source = Join-Path $tempRoot "source"

New-Item -ItemType Directory -Path $source -Force | Out-Null

# Pair by content id
Set-Content -LiteralPath (Join-Path $source "img_1001.heic") -Value "a"
Set-Content -LiteralPath (Join-Path $source "img_1001.mov") -Value "b"
# Pair by stripped numeric prefix + name key
Set-Content -LiteralPath (Join-Path $source "001_img_2001.jpg") -Value "c"
Set-Content -LiteralPath (Join-Path $source "002_img_2001.mov") -Value "d"
# Unmatched image + unmatched video
Set-Content -LiteralPath (Join-Path $source "img_3001.jpg") -Value "e"
Set-Content -LiteralPath (Join-Path $source "random.mov") -Value "f"

try {
  Write-Host "Test workspace: $tempRoot"

  & pwsh -NoProfile -File $scriptPath `
    -Path $source `
    -ExifTool $fakeExifTool `
    -MaxTimeDeltaSeconds 3

  $logs = Join-Path $source "_logs"
  $summaryFile = Get-LatestFile -Folder $logs -Pattern "livephoto_pairs_*.summary.json"
  Assert-True -Condition ($null -ne $summaryFile) -Message "Expected summary JSON."
  $summary = Get-Content -LiteralPath $summaryFile.FullName | ConvertFrom-Json

  Assert-True -Condition ($summary.images -eq 3) -Message "Expected 3 image files."
  Assert-True -Condition ($summary.videos -eq 3) -Message "Expected 3 video files."
  Assert-True -Condition ($summary.pairs -eq 2) -Message "Expected 2 matched pairs."
  Assert-True -Condition ($summary.unmatchedImages -eq 1) -Message "Expected 1 unmatched image."
  Assert-True -Condition ($summary.unmatchedVideos -eq 1) -Message "Expected 1 unmatched video."

  $pairsFile = Get-LatestFile -Folder $logs -Pattern "livephoto_pairs_*.pairs.csv"
  Assert-True -Condition ($null -ne $pairsFile) -Message "Expected pairs CSV."
  $pairs = @(Import-Csv -LiteralPath $pairsFile.FullName)
  Assert-True -Condition ($pairs.Count -eq 2) -Message "Expected 2 pair rows."
  Assert-True -Condition ($pairs.NameKey -contains "img_1001") -Message "Expected img_1001 pair."
  Assert-True -Condition ($pairs.NameKey -contains "img_2001") -Message "Expected img_2001 pair."

  # 2) Filtered run: only JPG/VIDEO and Apple/UNKNOWN model folders.
  $scoped = Join-Path $tempRoot "scoped"
  New-Item -ItemType Directory -Path (Join-Path $scoped "JPG\Apple iPhone 14 Pro") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $scoped "VIDEO\Apple iPhone 14 Pro") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $scoped "JPG\Apple iPhone 12 Pro") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $scoped "VIDEO\Apple iPhone 12 Pro") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $scoped "JPG\Sony A7 IV") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $scoped "VIDEO\GoPro HERO5 Black") -Force | Out-Null

  Set-Content -LiteralPath (Join-Path $scoped "JPG\Apple iPhone 14 Pro\img_1001.heic") -Value "a"
  Set-Content -LiteralPath (Join-Path $scoped "VIDEO\Apple iPhone 14 Pro\img_1001.mov") -Value "b"
  Set-Content -LiteralPath (Join-Path $scoped "JPG\Apple iPhone 12 Pro\001_img_2001.jpg") -Value "c"
  Set-Content -LiteralPath (Join-Path $scoped "VIDEO\Apple iPhone 12 Pro\002_img_2001.mov") -Value "d"
  Set-Content -LiteralPath (Join-Path $scoped "JPG\Sony A7 IV\img_3001.jpg") -Value "e"
  Set-Content -LiteralPath (Join-Path $scoped "VIDEO\GoPro HERO5 Black\random.mov") -Value "f"

  & pwsh -NoProfile -File $scriptPath `
    -Path $scoped `
    -ExifTool $fakeExifTool `
    -Stage "JPG,VIDEO,ELSE" `
    -ModelIncludeRegex '^(Apple |UNKNOWN$)' `
    -MaxTimeDeltaSeconds 3

  $scopedLogs = Join-Path $scoped "_logs"
  $scopedSummaryFile = Get-LatestFile -Folder $scopedLogs -Pattern "livephoto_pairs_*.summary.json"
  Assert-True -Condition ($null -ne $scopedSummaryFile) -Message "Expected scoped summary JSON."
  $scopedSummary = Get-Content -LiteralPath $scopedSummaryFile.FullName | ConvertFrom-Json

  Assert-True -Condition ($scopedSummary.images -eq 2) -Message "Scoped run should include only Apple images."
  Assert-True -Condition ($scopedSummary.videos -eq 2) -Message "Scoped run should include only Apple videos."
  Assert-True -Condition ($scopedSummary.pairs -eq 2) -Message "Scoped run should find 2 pairs."
  Assert-True -Condition ($scopedSummary.unmatchedImages -eq 0) -Message "Scoped run should have 0 unmatched images."
  Assert-True -Condition ($scopedSummary.unmatchedVideos -eq 0) -Message "Scoped run should have 0 unmatched videos."

  Write-Host ""
  Write-Host "Validate-LivePhoto-Pairs checks passed."
}
finally {
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepTemp) {
    Write-Host "Temp kept at: $tempRoot"
  }
}
