<#
.SYNOPSIS
  Reverses the moves recorded in one or more run logs (any script's
  _logs/*.log). Previews by default; pass -Action Move to move files back.
.DESCRIPTION
  Reads every "MOVE_DONE <source> -> <target>" line and, newest first, moves
  <target> back to <source>. A file is only moved back when it is still at the
  target and nothing occupies the original path; everything else is skipped and
  logged. Deleted files (Prune-Duplicate-Groups -Action Delete) cannot be undone.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string[]]$Log,
  [ValidateSet("Report", "Move")] [string]$Action = "Report",
  [switch]$WhatIf
)

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking

$Preview = ($Action -ne "Move") -or $WhatIf
$moves = New-Object System.Collections.Generic.List[object]
foreach ($l in $Log) {
  $full = Get-FullPath $l
  if (-not [IO.File]::Exists($full)) { Write-Error "Log not found: $full"; exit 2 }
  foreach ($line in [IO.File]::ReadLines($full)) {
    $p = $line.Split("`t")
    if ($p.Count -eq 4 -and $p[0] -eq "MOVE_DONE" -and $p[2] -eq "->") {
      $moves.Add([pscustomobject]@{ Source = $p[1]; Target = $p[3] })
    }
  }
}

$logDir = [IO.Path]::GetDirectoryName((Get-FullPath $Log[0]))
$logFile = Join-Path $logDir ("undo_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
Start-RunLog $logFile
Write-LogLine "RUN`tstart=$((Get-Date).ToString('o'))`taction=$Action`tpreview=$Preview`tlogs=$($Log -join ';')`tmoves=$($moves.Count)"

Write-Host "Moves found: $($moves.Count) in $($Log.Count) log(s)"
Write-Host "Action:      $Action$(if ($Preview) { ' (preview only, nothing will be moved)' })"

$c = [ordered]@{ restored = 0; planned = 0; skippedTargetMissing = 0; skippedSourceOccupied = 0; errors = 0 }
$shown = 0
for ($i = $moves.Count - 1; $i -ge 0; $i--) {
  $m = $moves[$i]
  if (-not [IO.File]::Exists($m.Target)) {
    $c.skippedTargetMissing++; Write-LogLine "SKIP_TARGET_MISSING`t$($m.Target)"; continue
  }
  if (Test-PathExists $m.Source) {
    $c.skippedSourceOccupied++; Write-LogLine "SKIP_SOURCE_OCCUPIED`t$($m.Source)"; continue
  }
  if ($Preview) {
    $c.planned++
    Write-LogLine "PLAN`t$($m.Target)`t->`t$($m.Source)"
    if ($shown -lt 20) { Write-Host "[Preview] $($m.Target) -> $($m.Source)"; $shown++ }
    continue
  }
  try {
    Ensure-Dir ([IO.Path]::GetDirectoryName($m.Source))
    Move-MediaFile -Source $m.Target -Target $m.Source
    Write-LogLine "MOVE_DONE`t$($m.Target)`t->`t$($m.Source)"
    $c.restored++
  }
  catch {
    $c.errors++
    $err = "ERROR`t$($m.Target)`t$($_.Exception.Message)"
    Write-LogLine $err
    Write-Warning $err
  }
}

Write-LogLine ("SUMMARY`t" + (($c.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`t"))
Stop-RunLog

Write-Host ""
Write-Host ("{0}: {1}  Skipped (not at target): {2}  Skipped (original path in use): {3}  Errors: {4}" -f $(if ($Preview) { "Planned" } else { "Restored" }), $(if ($Preview) { $c.planned } else { $c.restored }), $c.skippedTargetMissing, $c.skippedSourceOccupied, $c.errors)
Write-Host "Log: $logFile"
if ($c.errors -gt 0) { exit 3 }
