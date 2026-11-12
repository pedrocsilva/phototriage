<#
.SYNOPSIS
  Regroups a <Bucket>/<Camera> tree into Cameras|Phones|Others/<Camera>/<Bucket>.
  Default: report only; -Action Move moves files.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$DestRoot,
  [ValidateSet("Report", "Move")] [string]$Action = "Report",
  [string]$PhoneModelRegex = "^(Apple iPhone|Apple iPad|Google Nexus|Samsung Galaxy|HTC |Alcatel )",
  [string]$OtherModelRegex = "^(UNKNOWN)$",
  [int]$ProgressEvery = 5000,
  [switch]$PruneEmptySourceDirs,
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1"
Import-Module $modulePath -Force -DisableNameChecking

$stageBuckets = @("RAW", "JPG", "VIDEO", "ELSE")
$targetLeafByBucket = @{
  RAW   = "RAW"
  JPG   = "JPG"
  VIDEO = "VIDEO"
  ELSE  = "ELSE"
}

function Get-DeviceClass {
  param(
    [Parameter(Mandatory = $true)][string]$ModelName,
    [Parameter(Mandatory = $true)][string]$PhoneRegex,
    [Parameter(Mandatory = $true)][string]$OtherRegex
  )
  if ([string]::IsNullOrWhiteSpace($ModelName)) { return "Others" }
  if ($ModelName -match $OtherRegex) { return "Others" }
  if ($ModelName -match $PhoneRegex) { return "Phones" }
  return "Cameras"
}

function Get-RelativePartsFromBucket {
  param(
    [Parameter(Mandatory = $true)][string]$AbsolutePath,
    [Parameter(Mandatory = $true)][string]$BucketRoot
  )

  $rootNorm = ($BucketRoot -replace "/", "\").TrimEnd("\")
  $absNorm = ($AbsolutePath -replace "/", "\")

  if ($absNorm.StartsWith("\\?\")) { $absNorm = $absNorm.Substring(4) }
  if ($rootNorm.StartsWith("\\?\")) { $rootNorm = $rootNorm.Substring(4) }

  if (-not $absNorm.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
    return @()
  }

  $relative = $absNorm.Substring($rootNorm.Length).TrimStart("\")
  if ([string]::IsNullOrWhiteSpace($relative)) {
    return @()
  }

  return @($relative -split "\\+" | Where-Object { $_ -ne "" })
}

function Join-PathParts {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string[]]$Parts
  )

  $full = $BasePath
  foreach ($p in $Parts) {
    $full = Join-Path $full $p
  }
  return $full
}

$runStart = Get-Date
Ensure-Dir $DestRoot
Ensure-Dir (Join-Path $DestRoot "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$logFile = Join-Path $DestRoot "_logs/reclassify_tree_$stamp.log"
$manifestCsv = Join-Path $DestRoot "_logs/reclassify_tree_$stamp.manifest.csv"
$summaryJson = Join-Path $DestRoot "_logs/reclassify_tree_$stamp.summary.json"

Start-RunLog $logFile
$manifestRows = New-Object System.Collections.Generic.List[object]
$reservedTargets = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

$scanned = 0
$plannedMoves = 0
$moved = 0
$errors = 0
$skippedLayout = 0
$skippedAlreadyTarget = 0
$skippedUnknownBucket = 0
$prunedEmptyDirs = 0

$classCounts = @{
  Cameras = 0
  Phones  = 0
  Others  = 0
}
$bucketCounts = @{
  RAW   = 0
  JPG   = 0
  VIDEO = 0
  ELSE  = 0
}

Write-Host "Reclassifying media tree..."
Write-Host ("Started:         {0}" -f $runStart.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Host "DestRoot:        $DestRoot"
Write-Host "Action:          $Action"
Write-Host "WhatIf:          $WhatIf"
Write-Host "Prune empty:     $PruneEmptySourceDirs"
Write-Host "Log:             $logFile"

Write-LogLine "RUN`tstart=$runStart`tdestRoot=$DestRoot`taction=$Action`twhatif=$WhatIf`tpruneEmpty=$PruneEmptySourceDirs"
Write-LogLine "CONFIG`tphoneModelRegex=$PhoneModelRegex`totherModelRegex=$OtherModelRegex"

foreach ($bucket in $stageBuckets) {
  $bucketRoot = Join-Path $DestRoot $bucket
  if (-not (Test-Path -LiteralPath $bucketRoot -PathType Container)) {
    continue
  }

  Write-LogLine "PHASE`tname=scan_bucket`tvalue=$bucket"

  Get-ChildItem -LiteralPath $bucketRoot -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_
    $scanned++
    $bucketCounts[$bucket]++

    if (($scanned % $ProgressEvery) -eq 0) {
      $elapsedNow = (Get-Date) - $runStart
      $rateNow = if ($elapsedNow.TotalSeconds -gt 0) { [math]::Round($scanned / $elapsedNow.TotalSeconds, 1) } else { 0 }
      Write-Host ("Progress: scanned {0}, planned {1}, moved {2}, errors {3} ({4} files/s)" -f $scanned, $plannedMoves, $moved, $errors, $rateNow)
      Write-LogLine "PROGRESS`tscanned=$scanned`tplannedMoves=$plannedMoves`tmoved=$moved`terrors=$errors`trate=$rateNow"
    }

    $parts = Get-RelativePartsFromBucket -AbsolutePath $file.FullName -BucketRoot $bucketRoot
    if ($parts.Count -lt 2) {
      $skippedLayout++
      Write-LogLine "SKIP_LAYOUT`t$($file.FullName)"
      return
    }

    $model = Sanitize-Name $parts[0]
    if ([string]::IsNullOrWhiteSpace($model)) { $model = "UNKNOWN" }
    $class = Get-DeviceClass -ModelName $model -PhoneRegex $PhoneModelRegex -OtherRegex $OtherModelRegex
    $targetLeaf = $targetLeafByBucket[$bucket]
    if (-not $targetLeaf) {
      $skippedUnknownBucket++
      return
    }

    $subParts = @()
    if ($parts.Count -gt 1) {
      $subParts = @($parts[1..($parts.Count - 1)])
    }

    $targetDir = Join-Path (Join-Path (Join-Path $DestRoot $class) $model) $targetLeaf
    $initialTarget = Join-PathParts -BasePath $targetDir -Parts $subParts
    $targetPath = Get-UniqueTargetPath -targetPath $initialTarget -Reserved $reservedTargets

    if ($file.FullName.Equals($targetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      $skippedAlreadyTarget++
      Write-LogLine "SKIP_ALREADY_TARGET`t$($file.FullName)"
      return
    }

    $classCounts[$class]++
    $plannedMoves++

    $manifestRows.Add([pscustomobject]@{
      SourcePath = $file.FullName
      Bucket     = $bucket
      Model      = $model
      Class      = $class
      TargetPath = $targetPath
      Action     = if ($Action -eq "Move") { "MovePlanned" } else { "ReportOnly" }
    }) | Out-Null

    Write-LogLine "MOVE_PLANNED`t$($file.FullName)`t->`t$targetPath"

    if ($Action -eq "Move") {
      try {
        if ($WhatIf) {
          Write-Host "[WhatIf] MOVE `"$($file.FullName)`" -> `"$targetPath`""
        }
        else {
          Ensure-Dir (Split-Path -Parent $targetPath)
          Move-MediaFile -Source $file.FullName -Target $targetPath
          $moved++
          # Written to disk immediately so an interrupted run still has a full record.
          Write-LogLine "MOVE_DONE`t$($file.FullName)`t->`t$targetPath"
        }
      }
      catch {
        $errors++
        $err = "ERROR`t$($file.FullName)`t$($_.Exception.Message)"
        Write-Warning $err
        Write-LogLine $err
      }
    }
  }
}

if ($Action -eq "Move" -and -not $WhatIf -and $PruneEmptySourceDirs) {
  foreach ($bucket in $stageBuckets) {
    $bucketRoot = Join-Path $DestRoot $bucket
    $prunedEmptyDirs += Remove-EmptyDirectoryTree -RootPath $bucketRoot
  }
  Write-LogLine "INFO`tprunedEmptyDirs=$prunedEmptyDirs"
}

$manifestRows | Export-Csv -LiteralPath $manifestCsv -NoTypeInformation -Encoding UTF8

$elapsed = (Get-Date) - $runStart
$rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($scanned / $elapsed.TotalSeconds, 2) } else { 0 }

$summary = [ordered]@{
  runStarted            = $runStart.ToString("o")
  runEnded              = (Get-Date).ToString("o")
  destRoot              = $DestRoot
  action                = $Action
  whatIf                = [bool]$WhatIf
  pruneEmptySourceDirs  = [bool]$PruneEmptySourceDirs
  scannedFiles          = $scanned
  plannedMoves          = $plannedMoves
  moved                 = $moved
  errors                = $errors
  skippedLayout         = $skippedLayout
  skippedAlreadyTarget  = $skippedAlreadyTarget
  skippedUnknownBucket  = $skippedUnknownBucket
  prunedEmptyDirs       = $prunedEmptyDirs
  classCounts           = $classCounts
  bucketCounts          = $bucketCounts
  elapsedSeconds        = [math]::Round($elapsed.TotalSeconds, 2)
  scannedPerSecond      = $rate
  manifestCsv           = $manifestCsv
  logFile               = $logFile
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
Write-LogLine "SUMMARY`tscanned=$scanned`tplannedMoves=$plannedMoves`tmoved=$moved`terrors=$errors`telapsedSeconds=$([math]::Round($elapsed.TotalSeconds, 2))"
Stop-RunLog

Write-Host ""
Write-Host "Done."
Write-Host "Scanned files:      $scanned"
Write-Host "Planned moves:      $plannedMoves"
Write-Host "Moved:              $moved"
Write-Host "Errors:             $errors"
Write-Host "Skipped (layout):   $skippedLayout"
Write-Host "Skipped (in place): $skippedAlreadyTarget"
Write-Host "Pruned empty dirs:  $prunedEmptyDirs"
Write-Host "Class counts:       Cameras=$($classCounts.Cameras), Phones=$($classCounts.Phones), Others=$($classCounts.Others)"
Write-Host "Rate:               $rate files/s"
Write-Host "Manifest CSV:       $manifestCsv"
Write-Host "Summary JSON:       $summaryJson"
Write-Host "Log:                $logFile"
if ($errors -gt 0) { exit 3 }
