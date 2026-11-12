<#
.SYNOPSIS
  Finds RAW + JPG files of the same shot inside each camera folder.
  -Action MoveJpgToReview moves the lower-resolution file of each pair into a
  per-camera review folder. Default: report only.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$DestRoot,
  [ValidateSet("Cameras", "Phones", "Others")] [string]$Class = "Cameras",
  [string]$ModelIncludeRegex = ".*",
  [switch]$ExactOnly,
  [switch]$Recurse,
  [ValidateSet("Report", "MoveJpgToReview")] [string]$Action = "Report",
  [string]$ReviewFolderName = "_raw_jpg_dupes",
  [string]$ExifTool = "exiftool",
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking

$rawExts = @("arw", "nef", "raf", "dng", "cr2", "cr3", "orf", "rw2", "gpr")
$jpgExts = @("jpg", "jpeg", "heic")

function Parse-ExifDate([object]$item) {
  $subSecDto = Get-PropertyValue -item $item -name "SubSecDateTimeOriginal"
  $dto = Get-PropertyValue -item $item -name "DateTimeOriginal"
  $subSecCd = Get-PropertyValue -item $item -name "SubSecCreateDate"
  $cd = Get-PropertyValue -item $item -name "CreateDate"
  $dateCandidates = @(
    "$subSecDto",
    "$dto",
    "$subSecCd",
    "$cd"
  )
  foreach ($d in $dateCandidates) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    $text = $d.Trim()
    $m = [regex]::Match($text, '^(?<y>\d{4}):(?<M>\d{2}):(?<d>\d{2})\s+(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})(?:\.(?<frac>\d{1,9}))?(?:Z|[+\-]\d{2}:\d{2})?$')
    if ($m.Success) {
      try {
        $year = [int]$m.Groups['y'].Value
        $month = [int]$m.Groups['M'].Value
        $day = [int]$m.Groups['d'].Value
        $hour = [int]$m.Groups['h'].Value
        $minute = [int]$m.Groups['m'].Value
        $second = [int]$m.Groups['s'].Value
        $frac = $m.Groups['frac'].Value
        $ms = 0
        if (-not [string]::IsNullOrWhiteSpace($frac)) {
          $msText = ($frac + "000").Substring(0, 3)
          $ms = [int]$msText
        }
        return [datetime]::new($year, $month, $day, $hour, $minute, $second, $ms, [System.DateTimeKind]::Unspecified)
      }
      catch {
      }
    }
  }
  return $null
}

function Get-PropertyValue {
  param(
    [Parameter(Mandatory = $true)][object]$item,
    [Parameter(Mandatory = $true)][string]$name
  )
  $p = $item.PSObject.Properties[$name]
  if ($p) { return $p.Value }
  return $null
}

function Get-IntPropertyValue {
  param(
    [Parameter(Mandatory = $true)][object]$item,
    [Parameter(Mandatory = $true)][string[]]$names
  )
  foreach ($n in $names) {
    $v = Get-PropertyValue -item $item -name $n
    if ($null -eq $v) { continue }
    $parsed = 0
    if ([int]::TryParse("$v", [ref]$parsed)) { return $parsed }
  }
  return 0
}

function Get-MaxIntPropertyValue {
  param(
    [Parameter(Mandatory = $true)][object]$item,
    [Parameter(Mandatory = $true)][string[]]$names
  )
  $max = 0
  foreach ($n in $names) {
    $v = Get-IntPropertyValue -item $item -names @($n)
    if ($v -gt $max) { $max = $v }
  }
  return $max
}

function Get-PixelCount {
  param([Parameter(Mandatory = $true)][object]$row)
  if ($row.Width -gt 0 -and $row.Height -gt 0) {
    return ([int64]$row.Width * [int64]$row.Height)
  }
  return [int64]0
}

function Resolve-PixelCountFromFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Bucket,
    [Parameter(Mandatory = $true)][string]$ExifToolPath
  )
  try {
    $json = & $ExifToolPath -q -q -m -j -ImageWidth -ImageHeight -RawImageWidth -RawImageHeight -SubIFD:ImageWidth -SubIFD:ImageHeight -- $Path 2>$null
    $jsonText = [string]::Join("`n", @($json))
    if ([string]::IsNullOrWhiteSpace($jsonText)) { return [int64]0 }
    $item = @($jsonText | ConvertFrom-Json) | Select-Object -First 1
    if (-not $item) { return [int64]0 }

    $w = 0
    $h = 0
    if ($Bucket -eq "RAW") {
      $w = Get-MaxIntPropertyValue -item $item -names @("RawImageWidth", "SubIFD:ImageWidth", "ImageWidth")
      $h = Get-MaxIntPropertyValue -item $item -names @("RawImageHeight", "SubIFD:ImageHeight", "ImageHeight")
    }
    else {
      $w = Get-IntPropertyValue -item $item -names @("ImageWidth", "RawImageWidth")
      $h = Get-IntPropertyValue -item $item -names @("ImageHeight", "RawImageHeight")
    }
    if ($w -gt 0 -and $h -gt 0) { return ([int64]$w * [int64]$h) }
  }
  catch {
  }
  return [int64]0
}

function Normalize-BaseName([string]$fileName) {
  $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
  # Remove numeric duplicate suffixes such as "__1" and " (1)".
  $base = $base -replace "(__\d+)$", ""
  $base = $base -replace " \(\d+\)$", ""
  return $base.ToLowerInvariant()
}

function Get-ExactTimestampKey {
  param([Parameter(Mandatory = $true)][datetime]$DateTimeValue)
  return $DateTimeValue.ToString("yyyyMMddHHmmssfff", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Split-RelativeParts {
  param(
    [Parameter(Mandatory = $true)][string]$AbsolutePath,
    [Parameter(Mandatory = $true)][string]$Root
  )
  $rootNorm = ($Root -replace "/", "\").TrimEnd("\")
  $absNorm = ($AbsolutePath -replace "/", "\")
  if ($rootNorm.StartsWith("\\?\")) { $rootNorm = $rootNorm.Substring(4) }
  if ($absNorm.StartsWith("\\?\")) { $absNorm = $absNorm.Substring(4) }
  if (-not $absNorm.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
    return @()
  }
  $relative = $absNorm.Substring($rootNorm.Length).TrimStart("\")
  if ([string]::IsNullOrWhiteSpace($relative)) { return @() }
  return @($relative -split "\\+" | Where-Object { $_ -ne "" })
}

function Build-ItemsFromFilesystem {
  param([Parameter(Mandatory = $true)][string]$ModelPath)

  $rows = @()
  Get-ChildItem -LiteralPath $ModelPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rows += [pscustomobject]@{
      SourceFile = $_.FullName
      FileName   = $_.Name
    }
  }
  return @($rows)
}

$runStart = Get-Date
Ensure-Dir $DestRoot
Ensure-Dir (Join-Path $DestRoot "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$script:LogFile = Join-Path $DestRoot "_logs/raw_jpg_pairs_$stamp.log"
$pairsCsv = Join-Path $DestRoot "_logs/raw_jpg_pairs_$stamp.pairs.csv"
$unmatchedCsv = Join-Path $DestRoot "_logs/raw_jpg_pairs_$stamp.unmatched_jpg.csv"
$summaryJson = Join-Path $DestRoot "_logs/raw_jpg_pairs_$stamp.summary.json"

Start-RunLog $script:LogFile

$classRoot = Join-Path $DestRoot $Class
if (-not (Test-Path -LiteralPath $classRoot -PathType Container)) {
  Write-Host "Class path not found: $classRoot"
  exit 0
}

$exifToolVersion = (& $ExifTool -ver 2>$null)
if (-not $exifToolVersion) { $exifToolVersion = "unknown" }

Write-Host "Finding RAW/JPG pairs..."
Write-Host "Started:         $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "DestRoot:        $DestRoot"
Write-Host "Class:           $Class"
Write-Host "Model regex:     $ModelIncludeRegex"
Write-Host "Exact only:      $ExactOnly"
Write-Host "Recurse:         $Recurse"
Write-Host "Action:          $Action"
Write-Host "WhatIf:          $WhatIf"
Write-Host "ExifTool:        $exifToolVersion"
Write-Host "Log:             $script:LogFile"

Write-LogLine "RUN`tstart=$runStart`tdestRoot=$DestRoot`tclass=$Class`tmodelRegex=$ModelIncludeRegex`texactOnly=$ExactOnly`trecurse=$Recurse`taction=$Action`twhatif=$WhatIf`texiftoolVersion=$exifToolVersion"

$pairs = New-Object System.Collections.Generic.List[object]
$unmatchedJpg = New-Object System.Collections.Generic.List[object]
$modelPerf = New-Object System.Collections.Generic.List[object]

$modelsScanned = 0
$rawCount = 0
$jpgCount = 0
$pairCount = 0
$movedFiles = 0
$errors = 0

$modelDirs = Get-ChildItem -LiteralPath $classRoot -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match $ModelIncludeRegex }

foreach ($modelDir in $modelDirs) {
  $modelStart = Get-Date
  $rawDir = Join-Path $modelDir.FullName "RAW"
  $jpgDir = Join-Path $modelDir.FullName "JPG"
  if (-not (Test-Path -LiteralPath $rawDir -PathType Container)) { continue }
  if (-not (Test-Path -LiteralPath $jpgDir -PathType Container)) { continue }

  $modelsScanned++
  Write-Host ("Model start: {0}" -f $modelDir.Name)
  Write-LogLine ("MODEL_START`tname={0}`trawDir={1}`tjpgDir={2}" -f $modelDir.Name, $rawDir, $jpgDir)
  if (($modelsScanned % 10) -eq 0) {
    $elapsed = (Get-Date) - $runStart
    $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($modelsScanned / $elapsed.TotalSeconds, 1) } else { 0 }
    Write-Host ("Model progress: {0} models ({1} models/s), pairs {2}" -f $modelsScanned, $rate, $pairCount)
    Write-LogLine "PROGRESS`tmodelsScanned=$modelsScanned`tpairs=$pairCount`tmovedFiles=$movedFiles"
  }

  $extArgs = @()
  foreach ($e in ($rawExts + $jpgExts | Sort-Object -Unique)) {
    $extArgs += @("-ext", $e)
  }

  $modelExifStart = Get-Date
  Write-LogLine ("MODEL_PHASE`tname={0}`tphase=exif_start" -f $modelDir.Name)
  $scanArgs = @("-q", "-q", "-m", "-j", "-fast2")
  if ($Recurse) { $scanArgs += "-r" }
  $json = & $ExifTool @scanArgs `
    -DateTimeOriginal -SubSecDateTimeOriginal -CreateDate -SubSecCreateDate `
    -ImageWidth -ImageHeight -RawImageWidth -RawImageHeight -SubIFD:ImageWidth -SubIFD:ImageHeight `
    -FileName -FileTypeExtension `
    @($extArgs + @($rawDir, $jpgDir)) 2>$null
  $modelExifSeconds = ((Get-Date) - $modelExifStart).TotalSeconds
  Write-LogLine ("MODEL_PHASE`tname={0}`tphase=exif_end`telapsedSeconds={1}" -f $modelDir.Name, [math]::Round($modelExifSeconds, 3))

  $items = @()
  $jsonLines = @($json)
  Write-LogLine ("MODEL_PHASE`tname={0}`tphase=json_join_start`tlines={1}" -f $modelDir.Name, $jsonLines.Count)
  $jsonJoinStart = Get-Date
  $jsonText = [string]::Join("`n", $jsonLines)
  $jsonJoinSeconds = ((Get-Date) - $jsonJoinStart).TotalSeconds
  Write-LogLine ("MODEL_PHASE`tname={0}`tphase=json_join_end`telapsedSeconds={1}" -f $modelDir.Name, [math]::Round($jsonJoinSeconds, 3))
  if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
    $jsonParseStart = Get-Date
    Write-LogLine ("MODEL_PHASE`tname={0}`tphase=json_parse_start" -f $modelDir.Name)
    try {
      $items = @($jsonText | ConvertFrom-Json)
      $jsonParseSeconds = ((Get-Date) - $jsonParseStart).TotalSeconds
      Write-LogLine ("MODEL_PHASE`tname={0}`tphase=json_parse_end`telapsedSeconds={1}`titems={2}" -f $modelDir.Name, [math]::Round($jsonParseSeconds, 3), $items.Count)
    }
    catch {
      $items = @()
      Write-LogLine "WARN`tmodel=$($modelDir.Name)`tjsonParseFailed=$($_.Exception.Message)"
    }
  }

  if ($items.Count -eq 0) {
    Write-LogLine "INFO`tmodel=$($modelDir.Name)`tmetadataFallback=filesystem_only"
    $items = Build-ItemsFromFilesystem -ModelPath $modelDir.FullName
  }
  if ($items.Count -eq 0) {
    continue
  }

  $modelIndexStart = Get-Date
  $rawByExactTs = @{}
  $rawByBase = @{}
  $jpgRows = New-Object System.Collections.Generic.List[object]
  $modelRawCount = 0
  $modelJpgCount = 0

  foreach ($item in $items) {
    $src = "$($item.SourceFile)"
    if ([string]::IsNullOrWhiteSpace($src)) { continue }
    $parts = Split-RelativeParts -AbsolutePath $src -Root $modelDir.FullName
    if ($parts.Count -lt 2) { continue }
    $bucket = $parts[0].ToUpperInvariant()
    $ext = ([System.IO.Path]::GetExtension($src).TrimStart(".")).ToLowerInvariant()
    $dt = Parse-ExifDate -item $item
    $baseNorm = Normalize-BaseName -fileName (Split-Path -Leaf $src)

    $row = [pscustomobject]@{
      SourcePath = $src
      FileName   = Split-Path -Leaf $src
      Bucket     = $bucket
      Ext        = $ext
      DateTime   = $dt
      BaseNorm   = $baseNorm
      Width      = 0
      Height     = 0
    }

    if ($bucket -eq "RAW") {
      $row.Width = Get-MaxIntPropertyValue -item $item -names @("RawImageWidth", "SubIFD:ImageWidth", "ImageWidth")
      $row.Height = Get-MaxIntPropertyValue -item $item -names @("RawImageHeight", "SubIFD:ImageHeight", "ImageHeight")
    }
    else {
      $row.Width = Get-IntPropertyValue -item $item -names @("ImageWidth", "RawImageWidth")
      $row.Height = Get-IntPropertyValue -item $item -names @("ImageHeight", "RawImageHeight")
    }

    if ($bucket -eq "RAW" -and ($rawExts -contains $ext)) {
      $rawCount++
      $modelRawCount++
      if ($dt) {
        $exactTsKey = Get-ExactTimestampKey -DateTimeValue $dt
        if (-not $rawByExactTs.ContainsKey($exactTsKey)) { $rawByExactTs[$exactTsKey] = New-Object System.Collections.Generic.List[object] }
        [void]$rawByExactTs[$exactTsKey].Add($row)
      }
      if (-not $rawByBase.ContainsKey($baseNorm)) { $rawByBase[$baseNorm] = New-Object System.Collections.Generic.List[object] }
      [void]$rawByBase[$baseNorm].Add($row)
    }
    elseif ($bucket -eq "JPG" -and ($jpgExts -contains $ext)) {
      $jpgCount++
      $modelJpgCount++
      [void]$jpgRows.Add($row)
    }
  }
  $modelIndexSeconds = ((Get-Date) - $modelIndexStart).TotalSeconds

  $modelMatchStart = Get-Date
  $modelPairCount = 0
  $modelMoveCount = 0
  $modelErrorCount = 0
  $rawUsed = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($jpgRow in $jpgRows) {
    $src = $jpgRow.SourcePath
    $dt = $jpgRow.DateTime
    $baseNorm = $jpgRow.BaseNorm

    $bestRaw = $null
    $bestMethod = ""
    $bestScore = -1
    $bestDelta = [double]::PositiveInfinity

    if ($dt) {
      $exactTsKey = Get-ExactTimestampKey -DateTimeValue $dt
      if ($rawByExactTs.ContainsKey($exactTsKey)) {
        foreach ($cand in $rawByExactTs[$exactTsKey]) {
          if ($rawUsed.Contains($cand.SourcePath)) { continue }
          $bestRaw = $cand
          $bestMethod = "ExactTimestamp"
          $bestScore = 100
          $bestDelta = 0
          break
        }
      }
    }

    if (-not $ExactOnly -and -not $bestRaw -and $rawByBase.ContainsKey($baseNorm)) {
      foreach ($cand in $rawByBase[$baseNorm]) {
        if ($rawUsed.Contains($cand.SourcePath)) { continue }
        $bestRaw = $cand
        $bestMethod = "BaseNameMatch"
        $bestScore = 70
        $bestDelta = if ($dt -and $cand.DateTime) { [math]::Abs((New-TimeSpan -Start $cand.DateTime -End $dt).TotalSeconds) } else { -1 }
        break
      }
    }

    if ($bestRaw) {
      [void]$rawUsed.Add($bestRaw.SourcePath)
      $pairCount++
      $modelPairCount++
      $pairs.Add([pscustomobject]@{
        Model        = $modelDir.Name
        MatchMethod  = $bestMethod
        Score        = $bestScore
        DeltaSeconds = [math]::Round($bestDelta, 3)
        RawPath      = $bestRaw.SourcePath
        JpgPath      = $src
        RawPixels    = Get-PixelCount -row $bestRaw
        JpgPixels    = Get-PixelCount -row $jpgRow
      }) | Out-Null
      Write-LogLine "PAIR`tmodel=$($modelDir.Name)`tmethod=$bestMethod`tscore=$bestScore`traw=$($bestRaw.SourcePath)`tjpg=$src`trawPixels=$(Get-PixelCount -row $bestRaw)`tjpgPixels=$(Get-PixelCount -row $jpgRow)"

      if ($Action -eq "MoveJpgToReview") {
        $rawPixels = Get-PixelCount -row $bestRaw
        $jpgPixels = Get-PixelCount -row $jpgRow
        if ($rawPixels -eq 0) {
          $rawPixels = Resolve-PixelCountFromFile -Path $bestRaw.SourcePath -Bucket "RAW" -ExifToolPath $ExifTool
        }
        if ($jpgPixels -eq 0) {
          $jpgPixels = Resolve-PixelCountFromFile -Path $jpgRow.SourcePath -Bucket "JPG" -ExifToolPath $ExifTool
        }
        $moveCandidate = $jpgRow
        if ($rawPixels -gt 0 -and $jpgPixels -gt 0 -and $rawPixels -lt $jpgPixels) {
          $moveCandidate = $bestRaw
        }
        $reviewDir = Join-Path (Join-Path $modelDir.FullName $ReviewFolderName) $moveCandidate.Bucket
        $target = Get-UniqueTargetPath (Join-Path $reviewDir (Split-Path -Leaf $moveCandidate.SourcePath))
        try {
          if ($WhatIf) {
            Write-LogLine "MOVE_PLANNED`t$($moveCandidate.SourcePath)`t->`t$target"
          }
          else {
            Ensure-Dir $reviewDir
            Move-MediaFile -Source $moveCandidate.SourcePath -Target $target
            $movedFiles++
            $modelMoveCount++
            Write-LogLine "MOVE_DONE`t$($moveCandidate.SourcePath)`t->`t$target"
          }
        }
        catch {
          $errors++
          $modelErrorCount++
          $err = "ERROR`t$($moveCandidate.SourcePath)`t$($_.Exception.Message)"
          Write-Warning $err
          Write-LogLine $err
        }
      }
    }
    else {
      $unmatchedJpg.Add([pscustomobject]@{
        Model   = $modelDir.Name
        JpgPath = $src
      }) | Out-Null
    }
  }
  $modelMatchSeconds = ((Get-Date) - $modelMatchStart).TotalSeconds
  $modelTotalSeconds = ((Get-Date) - $modelStart).TotalSeconds
  $modelPerf.Add([pscustomobject]@{
    model        = $modelDir.Name
    items        = $items.Count
    rawSeen      = $modelRawCount
    jpgSeen      = $modelJpgCount
    pairs        = $modelPairCount
    movedFiles   = $modelMoveCount
    errors       = $modelErrorCount
    exifSeconds  = [math]::Round($modelExifSeconds, 3)
    indexSeconds = [math]::Round($modelIndexSeconds, 3)
    matchSeconds = [math]::Round($modelMatchSeconds, 3)
    totalSeconds = [math]::Round($modelTotalSeconds, 3)
  }) | Out-Null
  Write-Host ("Model done: {0} | raw={1} jpg={2} pairs={3} | exif={4}s index={5}s match={6}s total={7}s" -f `
      $modelDir.Name, $modelRawCount, $modelJpgCount, $modelPairCount, `
      [math]::Round($modelExifSeconds, 2), [math]::Round($modelIndexSeconds, 2), [math]::Round($modelMatchSeconds, 2), [math]::Round($modelTotalSeconds, 2))
  Write-LogLine ("MODEL`tname={0}`titems={1}`traw={2}`tjpg={3}`tpairs={4}`tmoved={5}`terrors={6}`texifSeconds={7}`tindexSeconds={8}`tmatchSeconds={9}`ttotalSeconds={10}" -f `
      $modelDir.Name, $items.Count, $modelRawCount, $modelJpgCount, $modelPairCount, $modelMoveCount, $modelErrorCount, `
      [math]::Round($modelExifSeconds, 3), [math]::Round($modelIndexSeconds, 3), [math]::Round($modelMatchSeconds, 3), [math]::Round($modelTotalSeconds, 3))
}

$pairs | Export-Csv -LiteralPath $pairsCsv -NoTypeInformation -Encoding UTF8
$unmatchedJpg | Export-Csv -LiteralPath $unmatchedCsv -NoTypeInformation -Encoding UTF8

$elapsedAll = (Get-Date) - $runStart
$summary = [ordered]@{
  runStarted        = $runStart.ToString("o")
  runEnded          = (Get-Date).ToString("o")
  destRoot          = $DestRoot
  class             = $Class
  modelIncludeRegex = $ModelIncludeRegex
  exactOnly         = [bool]$ExactOnly
  action            = $Action
  whatIf            = [bool]$WhatIf
  exifToolVersion   = "$exifToolVersion"
  modelsScanned     = $modelsScanned
  rawSeen           = $rawCount
  jpgSeen           = $jpgCount
  pairs             = $pairCount
  unmatchedJpg      = $unmatchedJpg.Count
  movedFiles        = $movedFiles
  movedJpg          = $movedFiles
  errors            = $errors
  elapsedSeconds    = [math]::Round($elapsedAll.TotalSeconds, 2)
  pairsCsv          = $pairsCsv
  unmatchedCsv      = $unmatchedCsv
  logFile           = $script:LogFile
  slowestModels     = @($modelPerf | Sort-Object totalSeconds -Descending | Select-Object -First 10)
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
Write-LogLine "SUMMARY`tmodelsScanned=$modelsScanned`trawSeen=$rawCount`tjpgSeen=$jpgCount`tpairs=$pairCount`tunmatchedJpg=$($unmatchedJpg.Count)`tmovedFiles=$movedFiles`terrors=$errors"
Stop-RunLog

Write-Host ""
Write-Host "Done."
Write-Host "Models scanned:     $modelsScanned"
Write-Host "RAW files seen:     $rawCount"
Write-Host "JPG files seen:     $jpgCount"
Write-Host "Pairs found:        $pairCount"
Write-Host "Unmatched JPG:      $($unmatchedJpg.Count)"
Write-Host "Moved files:        $movedFiles"
Write-Host "Errors:             $errors"
Write-Host "Pairs CSV:          $pairsCsv"
Write-Host "Unmatched JPG CSV:  $unmatchedCsv"
Write-Host "Summary JSON:       $summaryJson"
Write-Host "Log:                $script:LogFile"
if ($errors -gt 0) { exit 3 }
