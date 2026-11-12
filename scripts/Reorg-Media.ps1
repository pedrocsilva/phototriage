<#
.SYNOPSIS
  Moves photos and videos into DestRoot/<Bucket>/<Camera Model>/ using EXIF.
.DESCRIPTION
  Previews by default; pass -Action Move to move files. Never overwrites (name
  clashes get __1, __2, ...), and logs every planned and completed move to
  DestRoot/_logs/. After an interruption, rerun the same command: files that
  were already moved are no longer in Source, so it simply continues.
  Exit codes: 0 ok, 1 unreadable ExifTool output, 2 ExifTool missing, 3 some moves failed.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$DestRoot,
  [string]$ExifTool = "exiftool",
  [ValidateSet("RAW", "JPG", "VIDEO", "ELSE", "ALL")] [string]$Stage = "ALL",
  # Report (default) only previews and logs the planned moves. Move performs them.
  [ValidateSet("Report", "Move")] [string]$Action = "Report",
  # Kept for compatibility: forces a preview even with -Action Move.
  [switch]$WhatIf
)

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking
. (Join-Path $PSScriptRoot "../modules/ModelMap.ps1")

$Preview = ($Action -ne "Move") -or $WhatIf
$PreviewConsoleLines = 20

try { Assert-ExifToolAvailable $ExifTool }
catch { Write-Error $_.Exception.Message; exit 2 }

$Source = Get-FullPath $Source
$DestRoot = Get-FullPath $DestRoot
$logsDir = Join-Path $DestRoot "_logs"
Ensure-Dir $logsDir

$runStart = Get-Date
$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$logFile = Join-Path $logsDir "reorg_$stamp.log"
$reportFile = Join-Path $logsDir "reorg_$stamp.summary.json"

Start-RunLog $logFile

$exifToolVersion = (& $ExifTool -ver 2>$null)
if (-not $exifToolVersion) { $exifToolVersion = "unknown" }

Write-Host "Source:     $Source"
Write-Host "Dest:       $DestRoot"
Write-Host "Stage:      $Stage"
Write-Host "Action:     $Action$(if ($Preview) { ' (preview only, nothing will be moved)' })"
Write-Host "ExifTool:   $exifToolVersion"
Write-Host "Scanning metadata..."
Write-LogLine "RUN`tstart=$($runStart.ToString('o'))`tstage=$Stage`taction=$Action`tpreview=$Preview`tsource=$Source`tdest=$DestRoot`texiftoolVersion=$exifToolVersion"

# One ExifTool run for the whole tree, limited to sortable extensions.
$exifArgs = @("-q", "-q", "-m", "-j", "-r") + (Get-ExifToolExtArgs $Stage) + @("-Make", "-Model", "-DeviceModelName", "-AndroidModel", "--", $Source)
$json = & $ExifTool @exifArgs 2>$null

if (-not $json) {
  Write-Host "No files found or ExifTool returned no data."
  Write-LogLine "INFO`tno_exif_output"
  Stop-RunLog
  exit 0
}

try {
  $items = @([string]::Join("`n", @($json)) | ConvertFrom-Json -ErrorAction Stop)
}
catch {
  $msg = "ExifTool output could not be parsed as JSON; nothing was moved. $($_.Exception.Message)"
  Write-LogLine "FATAL`t$msg"
  Stop-RunLog
  Write-Error $msg
  exit 1
}

$reservedTargets = New-ReservedPathSet
$destPrefix = $DestRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$total = $items.Count
$c = [ordered]@{ processed = 0; moved = 0; skipped = 0; skippedMissingSource = 0; skippedInsideDest = 0; skippedNoBucket = 0; skippedStageFiltered = 0; errors = 0 }
$previewShown = 0

foreach ($item in $items) {
  $c.processed++
  if (($c.processed % 1000) -eq 0 -or $c.processed -eq $total) {
    $pct = [math]::Round(($c.processed / $total) * 100, 1)
    Write-Progress -Activity "Reorg-Media" -Status "$($c.processed) / $total ($pct%)" -PercentComplete $pct
  }

  $srcFile = $item.SourceFile
  if (-not $srcFile) { continue }
  $srcFile = [IO.Path]::GetFullPath($srcFile)   # ExifTool may report "/" on Windows

  # Already moved by an interrupted run (or removed): nothing to do.
  if (-not [IO.File]::Exists($srcFile)) { $c.skipped++; $c.skippedMissingSource++; continue }

  # Never re-sort what is already in the destination (DestRoot may live inside Source).
  if ($srcFile.StartsWith($destPrefix, $cmp)) { $c.skipped++; $c.skippedInsideDest++; continue }

  $bucket = Get-MediaBucket $srcFile
  if (-not $bucket) { $c.skipped++; $c.skippedNoBucket++; continue }
  if ($Stage -ne "ALL" -and $Stage -ne $bucket) { $c.skipped++; $c.skippedStageFiltered++; continue }

  $id = Get-CameraIdFromExif $item
  if ($script:ModelMap -and $script:ModelMap.ContainsKey($id)) { $id = $script:ModelMap[$id] }
  $destDir = [IO.Path]::Combine($DestRoot, $bucket, (Sanitize-Name $id))

  # Reserving targets keeps the preview accurate when two files share a name.
  $target = Get-UniqueTargetPath -targetPath ([IO.Path]::Combine($destDir, [IO.Path]::GetFileName($srcFile))) -Reserved $reservedTargets

  if ($Preview) {
    Write-LogLine "PLAN`t$srcFile`t->`t$target"
    if ($previewShown -lt $PreviewConsoleLines) { Write-Host "[Preview] $srcFile -> $target"; $previewShown++ }
    continue
  }

  try {
    Ensure-Dir $destDir
    Move-MediaFile -Source $srcFile -Target $target
    Write-LogLine "MOVE_DONE`t$srcFile`t->`t$target"
    $c.moved++
  }
  catch {
    $c.errors++
    $err = "ERROR`t$srcFile`t$($_.Exception.Message)"
    Write-LogLine $err
    Write-Warning $err
  }
}
Write-Progress -Activity "Reorg-Media" -Completed

$planned = $c.processed - $c.skipped
if ($Preview -and $previewShown -lt $planned) {
  Write-Host "[Preview] ... $($planned - $previewShown) more planned moves in the log"
}

$elapsed = (Get-Date) - $runStart
$rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($c.processed / $elapsed.TotalSeconds, 1) } else { 0 }

Write-Host ""
Write-Host "Done in $([math]::Round($elapsed.TotalSeconds, 1))s ($rate files/s)."
Write-Host ("Processed: {0}  {1}: {2}  Skipped: {3}  Errors: {4}" -f $c.processed, $(if ($Preview) { "Planned" } else { "Moved" }), $(if ($Preview) { $planned } else { $c.moved }), $c.skipped, $c.errors)
Write-Host ("  skipped: missing source {0}, inside dest {1}, no bucket {2}, stage filter {3}" -f $c.skippedMissingSource, $c.skippedInsideDest, $c.skippedNoBucket, $c.skippedStageFiltered)
Write-Host "Log:       $logFile"

$summary = [ordered]@{
  runStarted         = $runStart.ToString("o")
  runEnded           = (Get-Date).ToString("o")
  source             = $Source
  destination        = $DestRoot
  stage              = $Stage
  action             = $Action
  preview            = [bool]$Preview
  exifToolVersion    = "$exifToolVersion"
  plannedMoves       = $planned
  elapsedSeconds     = [math]::Round($elapsed.TotalSeconds, 2)
  processedPerSecond = $rate
  logFile            = $logFile
}
foreach ($k in $c.Keys) { $summary[$k] = $c[$k] }
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportFile -Encoding UTF8
Write-LogLine "SUMMARY`tprocessed=$($c.processed)`tmoved=$($c.moved)`tskipped=$($c.skipped)`terrors=$($c.errors)`telapsedSeconds=$([math]::Round($elapsed.TotalSeconds, 2))"

Stop-RunLog
if ($c.errors -gt 0) { exit 3 }
