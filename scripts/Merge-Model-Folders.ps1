<#
.SYNOPSIS
  Merges alias camera folders into their canonical name from
  modules/ModelMap.ps1 (e.g. JPG/iPhone 14 Pro -> JPG/Apple iPhone 14 Pro).
  Previews by default; -Action Move moves files and removes emptied folders.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$DestRoot,
  [ValidateSet("RAW", "JPG", "VIDEO", "ELSE", "ALL")] [string]$Stage = "ALL",
  # Report (default) only previews and logs the planned merges. Move performs them.
  [ValidateSet("Report", "Move")] [string]$Action = "Report",
  # Kept for compatibility: forces a preview even with -Action Move.
  [switch]$WhatIf
)

$ModulePath = Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1"
$MapPath = Join-Path $PSScriptRoot "../modules/ModelMap.ps1"

Import-Module $ModulePath -Force -DisableNameChecking
. $MapPath

$Preview = ($Action -ne "Move") -or $WhatIf
$runStart = Get-Date
Ensure-Dir $DestRoot
Ensure-Dir (Join-Path $DestRoot "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $DestRoot "_logs/merge_models_$stamp.log"
Start-RunLog $logFile
$previewShown = 0

$allBuckets = @("RAW", "JPG", "VIDEO", "ELSE")
$buckets = if ($Stage -eq "ALL") { $allBuckets } else { @($Stage) }

# Build alias -> canonical map using ModelMap entries.
$aliasMap = @{}
if ($script:ModelMap) {
  foreach ($k in $script:ModelMap.Keys) {
    $alias = Sanitize-Name "$k"
    $canon = Sanitize-Name "$($script:ModelMap[$k])"

    if (
      $alias -and $canon -and
      $alias -ne "UNKNOWN" -and
      $canon -ne "UNKNOWN" -and
      $alias -ne $canon
    ) {
      if (-not $aliasMap.ContainsKey($alias)) {
        $aliasMap[$alias] = $canon
      }
    }
  }
}

# Pragmatic fallback for old iPhone/iPad folder names.
foreach ($n in @("iPhone", "iPad")) {
  foreach ($i in 1..20) {
    $candidate = "$n $i"
    if (-not $aliasMap.ContainsKey($candidate)) {
      $aliasMap[$candidate] = "Apple $candidate"
    }
  }
}

$processedFolders = 0
$mergedFolders = 0
$movedFiles = 0
$errors = 0
$skipped = 0
$reservedTargets = New-ReservedPathSet

Write-Host "Merging model folders..."
Write-Host "Started: $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Dest:    $DestRoot"
Write-Host "Stage:   $Stage"
Write-Host "Action:  $Action$(if ($Preview) { ' (preview only, nothing will be moved)' })"
Write-Host "Log:     $logFile"
Write-LogLine "RUN`tstart=$runStart`tdest=$DestRoot`tstage=$Stage`taction=$Action`tpreview=$Preview"

foreach ($bucket in $buckets) {
  $bucketPath = Join-Path $DestRoot $bucket
  if (-not (Test-Path -LiteralPath $bucketPath)) {
    continue
  }

  Write-Host ""
  Write-Host "Bucket: $bucket"

  $modelDirs = Get-ChildItem -LiteralPath $bucketPath -Directory -ErrorAction SilentlyContinue
  foreach ($dir in $modelDirs) {
    $processedFolders++
    $srcName = $dir.Name
    $srcDir = $dir.FullName
    $targetName = $null

    if ($aliasMap.ContainsKey($srcName)) {
      $targetName = $aliasMap[$srcName]
    }
    elseif ($srcName -match '^iPhone ' -or $srcName -match '^iPad ') {
      $targetName = "Apple $srcName"
    }

    if (-not $targetName -or $targetName -eq $srcName) {
      $skipped++
      continue
    }

    $targetDir = Join-Path $bucketPath $targetName

    # -Force includes hidden files (e.g. dotfiles on macOS/Linux, hidden on Windows).
    # Enumeration errors are collected, not ignored: a folder we could not fully
    # read is never cleaned up.
    $enumErrors = @()
    $files = @(Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +enumErrors)
    if ($enumErrors.Count -gt 0) {
      foreach ($e in $enumErrors) {
        $errors++
        $err = "ERROR`tenumerate`t$srcDir`t$($e.Exception.Message)"
        Write-LogLine $err
        Write-Warning $err
      }
    }

    Write-Host ("Merge: {0}\{1} -> {0}\{2} ({3} files)" -f $bucket, $srcName, $targetName, $files.Count)

    foreach ($file in $files) {
      $targetPath = Get-UniqueTargetPath -targetPath (Join-Path $targetDir $file.Name) -Reserved $reservedTargets
      try {
        if ($Preview) {
          Write-LogLine "PLAN`t$($file.FullName)`t->`t$targetPath"
          if ($previewShown -lt 20) { Write-Host "[Preview] $($file.FullName) -> $targetPath"; $previewShown++ }
        }
        else {
          Ensure-Dir $targetDir
          Move-MediaFile -Source $file.FullName -Target $targetPath
          Write-LogLine "MOVE_DONE`t$($file.FullName)`t->`t$targetPath"
          $movedFiles++
        }
      }
      catch {
        $errors++
        $err = "ERROR`t$($file.FullName)`t$($_.Exception.Message)"
        Write-LogLine $err
        Write-Warning $err
      }
    }

    if (-not $Preview -and $enumErrors.Count -eq 0) {
      # Only ever removes directories that are completely empty (no recursive delete).
      [void](Remove-EmptyDirectoryTree -RootPath $srcDir -IncludeRoot)
    }

    $mergedFolders++
  }
}

$elapsed = (Get-Date) - $runStart
$elapsedText = "{0:00}:{1:00}:{2:00}" -f [math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds

Write-Host ""
Write-Host "Done."
Write-Host "Processed folders: $processedFolders"
Write-Host "Merged folders:    $mergedFolders"
Write-Host "Moved files:       $movedFiles"
Write-Host "Skipped folders:   $skipped"
Write-Host "Errors:            $errors"
Write-Host "Elapsed:           $elapsedText"
Write-Host "Log:               $logFile"

Write-LogLine "SUMMARY`tprocessedFolders=$processedFolders`tmergedFolders=$mergedFolders`tmovedFiles=$movedFiles`tskippedFolders=$skipped`terrors=$errors`telapsedSeconds=$([math]::Round($elapsed.TotalSeconds,2))"
Stop-RunLog
if ($errors -gt 0) { exit 3 }
