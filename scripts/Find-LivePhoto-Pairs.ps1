<#
.SYNOPSIS
  Finds Apple Live Photo pairs (still + short video) using ContentIdentifier,
  file name, camera and capture time. Read only; writes CSV reports to Path/_logs/.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$ExifTool = "exiftool",
  [int]$MaxTimeDeltaSeconds = 3,
  [string]$Stage = "ALL",
  [string]$ModelIncludeRegex = ""
)

$modulePath = Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1"
$mapPath = Join-Path $PSScriptRoot "../modules/ModelMap.ps1"
Import-Module $modulePath -Force -DisableNameChecking
. $mapPath

function Get-CameraIdFromExifItem([object]$item) {
  if ($item.Model) {
    if ($item.Make -and ($item.Model -notmatch [regex]::Escape($item.Make))) {
      return "$($item.Make) $($item.Model)"
    }
    return "$($item.Model)"
  }
  if ($item.DeviceModelName) { return "$($item.DeviceModelName)" }
  if ($item.AndroidModel) { return "$($item.AndroidModel)" }
  return "UNKNOWN"
}

function Get-CaptureDateUtc([object]$item) {
  $tags = @(
    "$($item.ContentCreateDate)",
    "$($item.SubSecDateTimeOriginal)",
    "$($item.DateTimeOriginal)",
    "$($item.CreationDate)",
    "$($item.CreateDate)",
    "$($item.MediaCreateDate)",
    "$($item.TrackCreateDate)",
    "$($item.FileModifyDate)"
  )
  foreach ($raw in $tags) {
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $norm = $raw.Trim()
    $norm = $norm -replace '^(\d{4}):(\d{2}):(\d{2})', '$1-$2-$3'
    $norm = $norm -replace '([+-]\d{2})(\d{2})$', '$1:$2'
    try {
      $dto = [DateTimeOffset]::Parse($norm, [System.Globalization.CultureInfo]::InvariantCulture)
      return $dto.UtcDateTime
    }
    catch {
      continue
    }
  }
  return $null
}

function Get-NameKey([string]$fileNameWithoutExt) {
  $n = $fileNameWithoutExt.ToLowerInvariant()
  $n = $n -replace '^\d+_', ''
  return $n
}

function Add-ToListMap {
  param(
    [hashtable]$Map,
    [string]$Key,
    [object]$Value
  )
  if (-not $Map.ContainsKey($Key)) {
    $Map[$Key] = New-Object System.Collections.Generic.List[object]
  }
  [void]$Map[$Key].Add($Value)
}

function Split-RelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$AbsolutePath,
    [Parameter(Mandatory = $true)][string]$Root
  )
  $rootNorm = $Root -replace '/', '\'
  $absNorm = $AbsolutePath -replace '/', '\'
  if ($rootNorm.StartsWith("\\?\")) { $rootNorm = $rootNorm.Substring(4) }
  if ($absNorm.StartsWith("\\?\")) { $absNorm = $absNorm.Substring(4) }
  $rootNorm = $rootNorm.TrimEnd('\')
  if (-not $absNorm.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) { return @() }
  $relative = $absNorm.Substring($rootNorm.Length).TrimStart('\')
  if ([string]::IsNullOrWhiteSpace($relative)) { return @() }
  return @($relative -split '\\+' | Where-Object { $_ -ne "" })
}

$runStart = Get-Date
Ensure-Dir $Path
Ensure-Dir (Join-Path $Path "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$logFile = Join-Path $Path "_logs/livephoto_pairs_$stamp.log"
$pairsCsv = Join-Path $Path "_logs/livephoto_pairs_$stamp.pairs.csv"
$unmatchedImagesCsv = Join-Path $Path "_logs/livephoto_pairs_$stamp.unmatched_images.csv"
$unmatchedVideosCsv = Join-Path $Path "_logs/livephoto_pairs_$stamp.unmatched_videos.csv"
$summaryJson = Join-Path $Path "_logs/livephoto_pairs_$stamp.summary.json"

Write-Host "Finding Live Photo pairs (batch exiftool)..."
Write-Host "Started:         $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Path:            $Path"
Write-Host "Max time delta:  $MaxTimeDeltaSeconds s"
Write-Host "Stage:           $Stage"
Write-Host "Model regex:     $(if ([string]::IsNullOrWhiteSpace($ModelIncludeRegex)) { '<none>' } else { $ModelIncludeRegex })"
Write-Host "Log:             $logFile"

Start-RunLog $logFile
Write-LogLine "RUN`tstart=$runStart`tpath=$Path`tmaxTimeDelta=$MaxTimeDeltaSeconds`tstage=$Stage`tmodelRegex=$ModelIncludeRegex"

$allBuckets = @("RAW", "JPG", "VIDEO", "ELSE")
$stageTokens = @(
  $Stage -split '[,\s;]+' |
    ForEach-Object { $_.Trim().ToUpperInvariant() } |
    Where-Object { $_ -ne "" }
)
if ($stageTokens.Count -eq 0) { $stageTokens = @("ALL") }
$invalid = @($stageTokens | Where-Object { $_ -notin @("RAW", "JPG", "VIDEO", "ELSE", "ALL") } | Select-Object -Unique)
if ($invalid.Count -gt 0) {
  throw "Invalid -Stage value(s): $($invalid -join ', '). Allowed: RAW,JPG,VIDEO,ELSE,ALL"
}
$selectedBuckets = if ($stageTokens -contains "ALL") { $allBuckets } else { @($stageTokens | Select-Object -Unique) }

$scanRoots = New-Object System.Collections.Generic.List[string]
foreach ($bucket in $selectedBuckets) {
  $bucketPath = Join-Path $Path $bucket
  if (-not (Test-Path -LiteralPath $bucketPath -PathType Container)) { continue }

  if ([string]::IsNullOrWhiteSpace($ModelIncludeRegex)) {
    [void]$scanRoots.Add($bucketPath)
    continue
  }

  foreach ($modelDir in [System.IO.Directory]::EnumerateDirectories($bucketPath)) {
    $model = Split-Path -Leaf $modelDir
    if ($model -match $ModelIncludeRegex) {
      [void]$scanRoots.Add($modelDir)
    }
  }
}

if ($scanRoots.Count -eq 0) {
  [void]$scanRoots.Add($Path)
}
Write-Host "Scan roots:       $($scanRoots.Count)"
Write-LogLine "INFO`tscanRoots=$($scanRoots.Count)"

$items = New-Object System.Collections.Generic.List[object]
foreach ($root in $scanRoots) {
  $json = & $ExifTool -q -q -m -j -r `
    -FileTypeExtension -Make -Model -DeviceModelName -AndroidModel `
    -ContentIdentifier -CompressorName -HandlerDescription `
    -ContentCreateDate -SubSecDateTimeOriginal -DateTimeOriginal `
    -CreationDate -CreateDate -MediaCreateDate -TrackCreateDate -FileModifyDate `
    "$root" 2>$null
  if (-not $json) { continue }
  foreach ($row in @($json | ConvertFrom-Json)) {
    [void]$items.Add($row)
  }
}

if ($items.Count -eq 0) {
  Write-Host "No metadata found (or folder empty)."
  Write-LogLine "INFO`tno_data=true"
  exit 0
}
$imageExtSet = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
foreach ($x in @("heic", "jpg", "jpeg")) { [void]$imageExtSet.Add($x) }
$videoExtSet = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
foreach ($x in @("mov", "mp4")) { [void]$videoExtSet.Add($x) }

$images = New-Object System.Collections.Generic.List[object]
$videos = New-Object System.Collections.Generic.List[object]
$seen = 0

foreach ($item in $items) {
  $seen++
  if (($seen % 10000) -eq 0) {
    $elapsedNow = (Get-Date) - $runStart
    $rate = if ($elapsedNow.TotalSeconds -gt 0) { [math]::Round($seen / $elapsedNow.TotalSeconds, 1) } else { 0 }
    Write-Host ("Parse progress: {0} items ({1} items/s)" -f $seen, $rate)
  }

  $src = "$($item.SourceFile)"
  if ([string]::IsNullOrWhiteSpace($src)) { continue }

  if (-not [string]::IsNullOrWhiteSpace($ModelIncludeRegex)) {
    $parts = Split-RelativePath -AbsolutePath $src -Root $Path
    if ($parts.Count -ge 2 -and ($allBuckets -contains $parts[0])) {
      $actualModel = $parts[1]
      if ($actualModel -notmatch $ModelIncludeRegex) { continue }
    }
  }

  $ext = "$($item.FileTypeExtension)"
  if ([string]::IsNullOrWhiteSpace($ext)) {
    $ext = [IO.Path]::GetExtension($src).TrimStart('.')
  }
  $ext = $ext.ToLowerInvariant()

  $leaf = Split-Path -Leaf $src
  $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
  $nameKey = Get-NameKey -fileNameWithoutExt $base
  $capture = Get-CaptureDateUtc -item $item

  $id = Get-CameraIdFromExifItem -item $item
  if ($script:ModelMap -and $script:ModelMap.ContainsKey($id)) {
    $id = $script:ModelMap[$id]
  }
  $model = Sanitize-Name $id

  $row = [pscustomobject]@{
    Path              = $src
    FileName          = $leaf
    BaseName          = $base
    NameKey           = $nameKey
    Ext               = $ext
    CaptureUtc        = $capture
    Model             = $model
    ContentIdentifier = "$($item.ContentIdentifier)"
  }

  if ($imageExtSet.Contains($ext)) { [void]$images.Add($row) }
  elseif ($videoExtSet.Contains($ext)) { [void]$videos.Add($row) }
}

Write-Host "Images:          $($images.Count)"
Write-Host "Videos:          $($videos.Count)"
Write-LogLine "INFO`timages=$($images.Count)`tvideos=$($videos.Count)"

$videosByNameKey = @{}
$videosByContentId = @{}
foreach ($v in $videos) {
  Add-ToListMap -Map $videosByNameKey -Key $v.NameKey -Value $v
  if (-not [string]::IsNullOrWhiteSpace($v.ContentIdentifier)) {
    Add-ToListMap -Map $videosByContentId -Key $v.ContentIdentifier -Value $v
  }
}

$usedVideos = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
$pairs = New-Object System.Collections.Generic.List[object]
$unmatchedImages = New-Object System.Collections.Generic.List[object]

foreach ($img in $images) {
  $candidatePool = New-Object System.Collections.Generic.List[object]

  if (-not [string]::IsNullOrWhiteSpace($img.ContentIdentifier) -and $videosByContentId.ContainsKey($img.ContentIdentifier)) {
    foreach ($v in $videosByContentId[$img.ContentIdentifier]) { [void]$candidatePool.Add($v) }
  }
  elseif ($videosByNameKey.ContainsKey($img.NameKey)) {
    foreach ($v in $videosByNameKey[$img.NameKey]) { [void]$candidatePool.Add($v) }
  }

  if ($candidatePool.Count -eq 0) {
    $unmatchedImages.Add([pscustomobject]@{
      ImagePath = $img.Path
      NameKey   = $img.NameKey
      Model     = $img.Model
    }) | Out-Null
    continue
  }

  $best = $null
  $bestScore = -1
  $bestDelta = [int]::MaxValue
  $bestType = "none"

  foreach ($v in $candidatePool) {
    if ($usedVideos.Contains($v.Path)) { continue }

    $score = 0
    $matchType = @()
    if (-not [string]::IsNullOrWhiteSpace($img.ContentIdentifier) -and $img.ContentIdentifier -eq $v.ContentIdentifier) {
      $score += 100
      $matchType += "content_id"
    }
    if ($img.NameKey -eq $v.NameKey) {
      $score += 70
      $matchType += "name_key"
    }
    if ($img.Model -ne "UNKNOWN" -and $img.Model -eq $v.Model) {
      $score += 20
      $matchType += "model"
    }

    $delta = [int]::MaxValue
    if ($img.CaptureUtc -and $v.CaptureUtc) {
      $delta = [math]::Abs([int](New-TimeSpan -Start $img.CaptureUtc -End $v.CaptureUtc).TotalSeconds)
      if ($delta -le $MaxTimeDeltaSeconds) {
        $score += 10
        $matchType += "time_close"
      }
    }

    if ($score -gt $bestScore -or ($score -eq $bestScore -and $delta -lt $bestDelta)) {
      $best = $v
      $bestScore = $score
      $bestDelta = $delta
      $bestType = if ($matchType.Count -gt 0) { $matchType -join "+" } else { "weak" }
    }
  }

  if ($null -eq $best -or $bestScore -lt 70) {
    $unmatchedImages.Add([pscustomobject]@{
      ImagePath = $img.Path
      NameKey   = $img.NameKey
      Model     = $img.Model
    }) | Out-Null
    continue
  }

  [void]$usedVideos.Add($best.Path)
  $pairs.Add([pscustomobject]@{
    ImagePath         = $img.Path
    VideoPath         = $best.Path
    MatchType         = $bestType
    Score             = $bestScore
    TimeDeltaSeconds  = if ($bestDelta -eq [int]::MaxValue) { $null } else { $bestDelta }
    ImageCaptureUtc   = if ($img.CaptureUtc) { $img.CaptureUtc.ToString("o") } else { "" }
    VideoCaptureUtc   = if ($best.CaptureUtc) { $best.CaptureUtc.ToString("o") } else { "" }
    ImageModel        = $img.Model
    VideoModel        = $best.Model
    NameKey           = $img.NameKey
    ContentIdentifier = $img.ContentIdentifier
  }) | Out-Null
}

$unmatchedVideos = New-Object System.Collections.Generic.List[object]
foreach ($v in $videos) {
  if ($usedVideos.Contains($v.Path)) { continue }
  $unmatchedVideos.Add([pscustomobject]@{
    VideoPath = $v.Path
    NameKey   = $v.NameKey
    Model     = $v.Model
  }) | Out-Null
}

$pairs |
  Sort-Object -Property @(
    @{ Expression = "Score"; Descending = $true },
    @{ Expression = "TimeDeltaSeconds"; Descending = $false },
    @{ Expression = "NameKey"; Descending = $false }
  ) |
  Export-Csv -LiteralPath $pairsCsv -NoTypeInformation -Encoding UTF8
$unmatchedImages | Export-Csv -LiteralPath $unmatchedImagesCsv -NoTypeInformation -Encoding UTF8
$unmatchedVideos | Export-Csv -LiteralPath $unmatchedVideosCsv -NoTypeInformation -Encoding UTF8

$elapsed = (Get-Date) - $runStart
$summary = [ordered]@{
  runStarted          = $runStart.ToString("o")
  runEnded            = (Get-Date).ToString("o")
  path                = $Path
  maxTimeDeltaSeconds = $MaxTimeDeltaSeconds
  scannedItems        = $items.Count
  images              = $images.Count
  videos              = $videos.Count
  pairs               = $pairs.Count
  unmatchedImages     = $unmatchedImages.Count
  unmatchedVideos     = $unmatchedVideos.Count
  elapsedSeconds      = [math]::Round($elapsed.TotalSeconds, 2)
  pairsCsv            = $pairsCsv
  unmatchedImagesCsv  = $unmatchedImagesCsv
  unmatchedVideosCsv  = $unmatchedVideosCsv
  logFile             = $logFile
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
Write-LogLine "SUMMARY`titems=$($items.Count)`timages=$($images.Count)`tvideos=$($videos.Count)`tpairs=$($pairs.Count)`tunmatchedImages=$($unmatchedImages.Count)`tunmatchedVideos=$($unmatchedVideos.Count)"

Write-Host ""
Write-Host "Done."
Write-Host "Scanned items:        $($items.Count)"
Write-Host "Images:               $($images.Count)"
Write-Host "Videos:               $($videos.Count)"
Write-Host "Pairs:                $($pairs.Count)"
Write-Host "Unmatched images:     $($unmatchedImages.Count)"
Write-Host "Unmatched videos:     $($unmatchedVideos.Count)"
Write-Host "Pairs CSV:            $pairsCsv"
Write-Host "Unmatched images CSV: $unmatchedImagesCsv"
Write-Host "Unmatched videos CSV: $unmatchedVideosCsv"
Write-Host "Summary JSON:         $summaryJson"
Write-Host "Log:                  $logFile"
