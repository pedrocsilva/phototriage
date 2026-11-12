<#
.SYNOPSIS
  Finds the same shot saved in two RAW formats (e.g. RAF + DNG) inside each
  camera's RAW folder. Read only; writes CSV reports to DestRoot/_logs/.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$DestRoot,
  [ValidateSet("Cameras", "Phones", "Others")] [string]$Class = "Cameras",
  [string]$ModelIncludeRegex = ".*",
  [switch]$Recurse,
  [string]$ExifTool = "exiftool"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking

$rawExts = @("arw", "nef", "raf", "dng", "cr2", "cr3", "orf", "rw2", "gpr")

function Get-PropertyValue {
  param(
    [Parameter(Mandatory = $true)][object]$item,
    [Parameter(Mandatory = $true)][string]$name
  )
  $p = $item.PSObject.Properties[$name]
  if ($p) { return $p.Value }
  return $null
}

function Normalize-CaptureDate {
  param([AllowNull()][string]$text)
  $value = "$text".Trim()
  if ([string]::IsNullOrWhiteSpace($value)) { return "" }
  return ($value -replace "\s+", " ").ToUpperInvariant()
}

function Get-CaptureKey {
  param([Parameter(Mandatory = $true)][object]$item)

  $t1 = Normalize-CaptureDate -text "$(Get-PropertyValue -item $item -name "SubSecDateTimeOriginal")"
  $t2 = Normalize-CaptureDate -text "$(Get-PropertyValue -item $item -name "DateTimeOriginal")"
  $t3 = Normalize-CaptureDate -text "$(Get-PropertyValue -item $item -name "SubSecCreateDate")"
  $t4 = Normalize-CaptureDate -text "$(Get-PropertyValue -item $item -name "CreateDate")"
  $ts = @($t1, $t2, $t3, $t4) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
  if (-not $ts) { return $null }

  $serial = "$(Get-PropertyValue -item $item -name "SerialNumber")".Trim().ToUpperInvariant()
  $internalSerial = "$(Get-PropertyValue -item $item -name "InternalSerialNumber")".Trim().ToUpperInvariant()
  $lens = "$(Get-PropertyValue -item $item -name "LensModel")".Trim().ToUpperInvariant()
  $rawW = "$(Get-PropertyValue -item $item -name "RawImageWidth")".Trim()
  $rawH = "$(Get-PropertyValue -item $item -name "RawImageHeight")".Trim()
  if ([string]::IsNullOrWhiteSpace($rawW)) { $rawW = "$(Get-PropertyValue -item $item -name "ImageWidth")".Trim() }
  if ([string]::IsNullOrWhiteSpace($rawH)) { $rawH = "$(Get-PropertyValue -item $item -name "ImageHeight")".Trim() }

  return "{0}|{1}|{2}|{3}|{4}|{5}" -f $ts, $serial, $internalSerial, $lens, $rawW, $rawH
}

$runStart = Get-Date
Ensure-Dir $DestRoot
Ensure-Dir (Join-Path $DestRoot "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$script:LogFile = Join-Path $DestRoot "_logs/raw_format_pairs_$stamp.log"
$groupsCsv = Join-Path $DestRoot "_logs/raw_format_pairs_$stamp.groups.csv"
$membersCsv = Join-Path $DestRoot "_logs/raw_format_pairs_$stamp.members.csv"
$summaryJson = Join-Path $DestRoot "_logs/raw_format_pairs_$stamp.summary.json"

Start-RunLog $script:LogFile

$classRoot = Join-Path $DestRoot $Class
if (-not (Test-Path -LiteralPath $classRoot -PathType Container)) {
  Write-Host "Class path not found: $classRoot"
  exit 0
}

$exifToolVersion = (& $ExifTool -ver 2>$null)
if (-not $exifToolVersion) { $exifToolVersion = "unknown" }

Write-Host "Finding RAW-format same-capture groups..."
Write-Host "Started:         $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "DestRoot:        $DestRoot"
Write-Host "Class:           $Class"
Write-Host "Model regex:     $ModelIncludeRegex"
Write-Host "Recurse:         $Recurse"
Write-Host "ExifTool:        $exifToolVersion"
Write-Host "Log:             $script:LogFile"

Write-LogLine "RUN`tstart=$runStart`tdestRoot=$DestRoot`tclass=$Class`tmodelRegex=$ModelIncludeRegex`trecurse=$Recurse`texiftoolVersion=$exifToolVersion"

$groupsOut = New-Object System.Collections.Generic.List[object]
$membersOut = New-Object System.Collections.Generic.List[object]
$modelPerf = New-Object System.Collections.Generic.List[object]

$modelsScanned = 0
$rawSeen = 0
$candidateGroups = 0
$candidateFiles = 0
$errors = 0
$groupId = 0

$modelDirs = Get-ChildItem -LiteralPath $classRoot -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match $ModelIncludeRegex }

foreach ($modelDir in $modelDirs) {
  $rawDir = Join-Path $modelDir.FullName "RAW"
  if (-not (Test-Path -LiteralPath $rawDir -PathType Container)) { continue }

  $modelsScanned++
  $modelStart = Get-Date
  Write-Host ("Model start: {0}" -f $modelDir.Name)

  $extArgs = @()
  foreach ($e in ($rawExts | Sort-Object -Unique)) { $extArgs += @("-ext", $e) }

  $scanArgs = @("-q", "-q", "-m", "-j", "-fast2")
  if ($Recurse) { $scanArgs += "-r" }

  $exifStart = Get-Date
  $json = & $ExifTool @scanArgs `
    -DateTimeOriginal -SubSecDateTimeOriginal -CreateDate -SubSecCreateDate `
    -SerialNumber -InternalSerialNumber -LensModel `
    -RawImageWidth -RawImageHeight -ImageWidth -ImageHeight `
    -FileName -FileTypeExtension -SourceFile `
    @($extArgs + @($rawDir)) 2>$null
  $exifSeconds = ((Get-Date) - $exifStart).TotalSeconds

  $jsonParseStart = Get-Date
  $items = @()
  try {
    $jsonText = [string]::Join("`n", @($json))
    if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
      $items = @($jsonText | ConvertFrom-Json)
    }
  }
  catch {
    $errors++
    Write-LogLine ("ERROR`tmodel={0}`tjsonParseFailed={1}" -f $modelDir.Name, $_.Exception.Message)
    continue
  }
  $jsonParseSeconds = ((Get-Date) - $jsonParseStart).TotalSeconds

  $groupStart = Get-Date
  $rawRows = New-Object System.Collections.Generic.List[object]
  foreach ($item in $items) {
    $src = "$(Get-PropertyValue -item $item -name "SourceFile")"
    if ([string]::IsNullOrWhiteSpace($src)) { continue }

    $ext = ([System.IO.Path]::GetExtension($src).TrimStart(".")).ToLowerInvariant()
    if (-not ($rawExts -contains $ext)) { continue }

    $rawSeen++
    $captureKey = Get-CaptureKey -item $item
    if ([string]::IsNullOrWhiteSpace($captureKey)) { continue }

    $row = [pscustomobject]@{
      Model      = $modelDir.Name
      SourcePath = $src
      FileName   = Split-Path -Leaf $src
      Ext        = $ext
      CaptureKey = $captureKey
    }
    $rawRows.Add($row) | Out-Null
  }

  $modelGroups = 0
  $modelCandidateFiles = 0
  foreach ($group in ($rawRows | Group-Object CaptureKey)) {
    $keyText = "$($group.Name)"
    $rows = @($group.Group)
    if ($rows.Count -lt 2) { continue }

    $extSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $rows) { [void]$extSet.Add($r.Ext) }
    if ($extSet.Count -lt 2) { continue }

    $groupId++
    $modelGroups++
    $candidateGroups++
    $modelCandidateFiles += $rows.Count
    $candidateFiles += $rows.Count

    $sortedRows = @($rows | Sort-Object SourcePath)
    $extsJoined = ((@($extSet) | Sort-Object) -join ",")
    $groupsOut.Add([pscustomobject]@{
      GroupId      = $groupId
      Model        = $modelDir.Name
      Files        = $sortedRows.Count
      DistinctExts = $extSet.Count
      Exts         = $extsJoined
      CaptureKey   = $keyText
      FirstPath    = $sortedRows[0].SourcePath
    }) | Out-Null

    foreach ($r in $sortedRows) {
      $membersOut.Add([pscustomobject]@{
        GroupId    = $groupId
        Model      = $r.Model
        Ext        = $r.Ext
        SourcePath = $r.SourcePath
      }) | Out-Null
    }
  }
  $groupSeconds = ((Get-Date) - $groupStart).TotalSeconds
  $modelTotalSeconds = ((Get-Date) - $modelStart).TotalSeconds

  $modelPerf.Add([pscustomobject]@{
    model            = $modelDir.Name
    rawSeen          = @($items | Where-Object { $rawExts -contains (($_.FileTypeExtension).ToString().ToLowerInvariant()) }).Count
    candidateGroups  = $modelGroups
    candidateFiles   = $modelCandidateFiles
    exifSeconds      = [math]::Round($exifSeconds, 3)
    jsonParseSeconds = [math]::Round($jsonParseSeconds, 3)
    groupSeconds     = [math]::Round($groupSeconds, 3)
    totalSeconds     = [math]::Round($modelTotalSeconds, 3)
  }) | Out-Null

  Write-Host ("Model done: {0} | candidateGroups={1} candidateFiles={2} | exif={3}s parse={4}s group={5}s total={6}s" -f `
      $modelDir.Name, $modelGroups, $modelCandidateFiles, `
      [math]::Round($exifSeconds, 2), [math]::Round($jsonParseSeconds, 2), [math]::Round($groupSeconds, 2), [math]::Round($modelTotalSeconds, 2))
  Write-LogLine ("MODEL`tname={0}`tcandidateGroups={1}`tcandidateFiles={2}`texifSeconds={3}`tjsonParseSeconds={4}`tgroupSeconds={5}`ttotalSeconds={6}" -f `
      $modelDir.Name, $modelGroups, $modelCandidateFiles, `
      [math]::Round($exifSeconds, 3), [math]::Round($jsonParseSeconds, 3), [math]::Round($groupSeconds, 3), [math]::Round($modelTotalSeconds, 3))
}

$groupsOut | Export-Csv -LiteralPath $groupsCsv -NoTypeInformation -Encoding UTF8
$membersOut | Export-Csv -LiteralPath $membersCsv -NoTypeInformation -Encoding UTF8

$elapsedAll = (Get-Date) - $runStart
$summary = [ordered]@{
  runStarted       = $runStart.ToString("o")
  runEnded         = (Get-Date).ToString("o")
  destRoot         = $DestRoot
  class            = $Class
  modelIncludeRegex = $ModelIncludeRegex
  recurse          = [bool]$Recurse
  exifToolVersion  = "$exifToolVersion"
  modelsScanned    = $modelsScanned
  rawSeen          = $rawSeen
  candidateGroups  = $candidateGroups
  candidateFiles   = $candidateFiles
  errors           = $errors
  elapsedSeconds   = [math]::Round($elapsedAll.TotalSeconds, 2)
  groupsCsv        = $groupsCsv
  membersCsv       = $membersCsv
  logFile          = $script:LogFile
  slowestModels    = @($modelPerf | Sort-Object totalSeconds -Descending | Select-Object -First 10)
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
Write-LogLine "SUMMARY`tmodelsScanned=$modelsScanned`trawSeen=$rawSeen`tcandidateGroups=$candidateGroups`tcandidateFiles=$candidateFiles`terrors=$errors"
Stop-RunLog

Write-Host ""
Write-Host "Done."
Write-Host "Models scanned:     $modelsScanned"
Write-Host "RAW files seen:     $rawSeen"
Write-Host "Candidate groups:   $candidateGroups"
Write-Host "Candidate files:    $candidateFiles"
Write-Host "Errors:             $errors"
Write-Host "Groups CSV:         $groupsCsv"
Write-Host "Members CSV:        $membersCsv"
Write-Host "Summary JSON:       $summaryJson"
Write-Host "Log:                $script:LogFile"
