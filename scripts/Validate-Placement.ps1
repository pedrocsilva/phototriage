<#
.SYNOPSIS
  Checks that every file under DestRoot is in the bucket and camera folder its
  extension and EXIF say. -Action MoveMismatches moves misplaced files.
  Default: report only.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$DestRoot,
  [string]$ExifTool = "exiftool",
  [ValidateSet("RAW", "JPG", "VIDEO", "ELSE", "ALL")] [string]$Stage = "ALL",
  [ValidateSet("Report", "MoveMismatches")] [string]$Action = "Report",
  [switch]$WhatIf
)

$modulePath = Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1"
$mapPath = Join-Path $PSScriptRoot "../modules/ModelMap.ps1"
Import-Module $modulePath -Force -DisableNameChecking
. $mapPath

$allBucketNames = @("RAW", "JPG", "VIDEO", "ELSE")
$selectedBuckets = if ($Stage -eq "ALL") { $allBucketNames } else { @($Stage) }

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
  if (-not $absNorm.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
    return @()
  }
  $relative = $absNorm.Substring($rootNorm.Length).TrimStart('\')
  if ([string]::IsNullOrWhiteSpace($relative)) { return @() }
  return @($relative -split '\\+' | Where-Object { $_ -ne "" })
}

$runStart = Get-Date
Ensure-Dir $DestRoot
Ensure-Dir (Join-Path $DestRoot "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$logFile = Join-Path $DestRoot "_logs/validate_placement_$stamp.log"
$csvFile = Join-Path $DestRoot "_logs/validate_placement_$stamp.mismatches.csv"
$summaryJson = Join-Path $DestRoot "_logs/validate_placement_$stamp.summary.json"

$scanRoots = New-Object System.Collections.Generic.List[string]
foreach ($bucket in $selectedBuckets) {
  $bucketPath = Join-Path $DestRoot $bucket
  if (Test-Path -LiteralPath $bucketPath -PathType Container) {
    [void]$scanRoots.Add($bucketPath)
  }
}

Write-Host "Validating folder placement (batch exiftool)..."
Write-Host "Started:         $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "DestRoot:        $DestRoot"
Write-Host "Stage:           $Stage"
Write-Host "Action:          $Action"
Write-Host "WhatIf:          $WhatIf"
Write-Host "Log:             $logFile"

Start-RunLog $logFile
Write-LogLine "RUN`tstart=$runStart`tdestRoot=$DestRoot`tstage=$Stage`taction=$Action`twhatif=$WhatIf"

if ($scanRoots.Count -eq 0) {
  Write-Host "No matching stage roots found under destination."
  Write-LogLine "INFO`tno_scan_roots=true"
  Stop-RunLog
  exit 0
}

$exifToolVersion = (& $ExifTool -ver 2>$null)
if (-not $exifToolVersion) { $exifToolVersion = "unknown" }
Write-Host "ExifTool:        $exifToolVersion"
Write-LogLine "INFO`texiftoolVersion=$exifToolVersion"

Write-LogLine "PHASE`tname=scan_metadata"
$items = New-Object System.Collections.Generic.List[object]
foreach ($root in $scanRoots) {
  $json = & $ExifTool -q -q -m -j -r -Make -Model -DeviceModelName -AndroidModel "$root" 2>$null
  if (-not $json) { continue }
  foreach ($row in @($json | ConvertFrom-Json)) {
    [void]$items.Add($row)
  }
}
if ($items.Count -eq 0) {
  Write-Host "No files discovered in selected stage roots."
  Write-LogLine "INFO`tno_files=true"
  Stop-RunLog
  exit 0
}
$total = $items.Count

$mismatchRows = New-Object System.Collections.Generic.List[object]
$processed = 0
$outsideLayout = 0
$unknownExt = 0
$validChecked = 0
$mismatches = 0
$plannedMoves = 0
$moved = 0
$errors = 0
$reasonCounts = @{
  WrongBucket = 0
  WrongModel = 0
  WrongBucketAndModel = 0
  InvalidPathLayout = 0
}

Write-LogLine "PHASE`tname=validate_paths"
foreach ($item in $items) {
  $processed++
  if (($processed % 10000) -eq 0 -or $processed -eq $total) {
    $elapsedNow = (Get-Date) - $runStart
    $rate = if ($elapsedNow.TotalSeconds -gt 0) { [math]::Round($processed / $elapsedNow.TotalSeconds, 1) } else { 0 }
    Write-Host ("Validate progress: {0}/{1} ({2} files/s), mismatches {3}" -f $processed, $total, $rate, $mismatches)
    Write-LogLine "PROGRESS`tprocessed=$processed`ttotal=$total`trate=$rate`tmismatches=$mismatches"
  }

  $src = "$($item.SourceFile)"
  if ([string]::IsNullOrWhiteSpace($src)) { continue }

  $parts = Split-RelativePath -AbsolutePath $src -Root $DestRoot
  if ($parts.Count -lt 2) {
    $outsideLayout++
    $reasonCounts.InvalidPathLayout++
    continue
  }

  $actualBucket = $parts[0]
  $actualModel = $parts[1]
  if ($selectedBuckets -notcontains $actualBucket) {
    $outsideLayout++
    continue
  }

  $ext = [IO.Path]::GetExtension($src).TrimStart('.').ToLowerInvariant()
  $expectedBucket = Get-MediaBucket $ext
  if (-not $expectedBucket) {
    $unknownExt++
    continue
  }

  $validChecked++
  $id = Get-CameraIdFromExif -item $item
  if ($script:ModelMap -and $script:ModelMap.ContainsKey($id)) {
    $id = $script:ModelMap[$id]
  }
  $expectedModel = Sanitize-Name $id

  $bucketMismatch = $actualBucket -ne $expectedBucket
  $modelMismatch = $actualModel -ne $expectedModel
  if (-not $bucketMismatch -and -not $modelMismatch) {
    continue
  }

  $mismatches++
  $reason = if ($bucketMismatch -and $modelMismatch) {
    $reasonCounts.WrongBucketAndModel++
    "WrongBucketAndModel"
  }
  elseif ($bucketMismatch) {
    $reasonCounts.WrongBucket++
    "WrongBucket"
  }
  else {
    $reasonCounts.WrongModel++
    "WrongModel"
  }

  $expectedDir = Join-Path (Join-Path $DestRoot $expectedBucket) $expectedModel
  $targetPath = Join-Path $expectedDir (Split-Path -Leaf $src)

  $plannedMoves++
  $row = [pscustomobject]@{
    Reason        = $reason
    CurrentPath   = $src
    CurrentBucket = $actualBucket
    CurrentModel  = $actualModel
    ExpectedPath  = $targetPath
    ExpectedBucket= $expectedBucket
    ExpectedModel = $expectedModel
    Action        = if ($Action -eq "MoveMismatches") { "MovePlanned" } else { "ReportOnly" }
  }
  $mismatchRows.Add($row) | Out-Null
  Write-LogLine "MISMATCH`t$reason`t$src`t->`t$targetPath"

  if ($Action -eq "MoveMismatches") {
    try {
      if (-not $WhatIf) {
        Ensure-Dir $expectedDir
        $targetPath = Get-UniqueTargetPath $targetPath
        Move-MediaFile -Source $src -Target $targetPath
        $moved++
        Write-LogLine "MOVE_DONE`t$src`t->`t$targetPath"
      }
    }
    catch {
      $errors++
      $err = "ERROR`t$src`t$($_.Exception.Message)"
      Write-Warning $err
      Write-LogLine $err
    }
  }
}

$mismatchRows | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8

$elapsed = (Get-Date) - $runStart
$summary = [ordered]@{
  runStarted             = $runStart.ToString("o")
  runEnded               = (Get-Date).ToString("o")
  destRoot               = $DestRoot
  stage                  = $Stage
  action                 = $Action
  whatIf                 = [bool]$WhatIf
  exifToolVersion        = "$exifToolVersion"
  scannedItems           = $total
  validChecked           = $validChecked
  mismatches             = $mismatches
  plannedMoves           = $plannedMoves
  moved                  = $moved
  errors                 = $errors
  outsideLayoutSkipped   = $outsideLayout
  unknownExtensionSkipped= $unknownExt
  reasonWrongBucket      = $reasonCounts.WrongBucket
  reasonWrongModel       = $reasonCounts.WrongModel
  reasonWrongBucketModel = $reasonCounts.WrongBucketAndModel
  reasonInvalidPathLayout= $reasonCounts.InvalidPathLayout
  elapsedSeconds         = [math]::Round($elapsed.TotalSeconds, 2)
  mismatchesCsv          = $csvFile
  logFile                = $logFile
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
Write-LogLine "SUMMARY`tscanned=$total`tchecked=$validChecked`tmismatches=$mismatches`tplannedMoves=$plannedMoves`tmoved=$moved`terrors=$errors"
Stop-RunLog

Write-Host ""
Write-Host "Done."
Write-Host "Scanned items:         $total"
Write-Host "Valid checked:         $validChecked"
Write-Host "Mismatches:            $mismatches"
Write-Host "Planned moves:         $plannedMoves"
Write-Host "Moved:                 $moved"
Write-Host "Errors:                $errors"
Write-Host "Skipped (layout):      $outsideLayout"
Write-Host "Skipped (unknown ext): $unknownExt"
Write-Host "Mismatches CSV:        $csvFile"
Write-Host "Summary JSON:          $summaryJson"
Write-Host "Log:                   $logFile"
if ($errors -gt 0) { exit 3 }
