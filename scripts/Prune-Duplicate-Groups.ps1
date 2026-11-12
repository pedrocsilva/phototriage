<#
.SYNOPSIS
  Keeps one file per duplicate group created by Find-Duplicates and
  permanently deletes the rest, but only files verified byte-identical (SHA-256)
  to the kept one. Default: report only; -Action Delete deletes.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$DuplicatesRoot,
  [ValidateSet("RAW", "JPG", "VIDEO", "ELSE", "ALL")] [string]$Stage = "ALL",
  [ValidateSet("Report", "Delete")] [string]$Action = "Report",
  [ValidateSet("FirstIndex", "Oldest", "Newest", "Largest")] [string]$KeepRule = "FirstIndex",
  [switch]$WhatIf
)

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking

$runStart = Get-Date
Ensure-Dir $DuplicatesRoot
Ensure-Dir (Join-Path $DuplicatesRoot "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$logFile = Join-Path $DuplicatesRoot "_logs/prune_dupes_$stamp.log"
$reportCsv = Join-Path $DuplicatesRoot "_logs/prune_dupes_$stamp.csv"
$summaryJson = Join-Path $DuplicatesRoot "_logs/prune_dupes_$stamp.summary.json"

function Get-FileOrderKey([System.IO.FileInfo]$f) {
  $m = [regex]::Match($f.Name, '^(?<idx>\d+)_')
  if ($m.Success) { return [int]$m.Groups['idx'].Value }
  return [int]::MaxValue
}

function Select-KeepFile {
  param(
    [System.Collections.Generic.List[System.IO.FileInfo]]$Files,
    [string]$Rule
  )

  switch ($Rule) {
    "FirstIndex" {
      return $Files |
        Sort-Object @{ Expression = { Get-FileOrderKey $_ }; Ascending = $true },
        @{ Expression = { $_.Name }; Ascending = $true } |
        Select-Object -First 1
    }
    "Oldest" {
      return $Files |
        Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Ascending = $true },
        @{ Expression = { $_.FullName }; Ascending = $true } |
        Select-Object -First 1
    }
    "Newest" {
      return $Files |
        Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Ascending = $false },
        @{ Expression = { $_.FullName }; Ascending = $true } |
        Select-Object -First 1
    }
    "Largest" {
      return $Files |
        Sort-Object @{ Expression = { $_.Length }; Ascending = $false },
        @{ Expression = { $_.FullName }; Ascending = $true } |
        Select-Object -First 1
    }
  }
}

# Group folders created by Find-Duplicates.ps1 are named "<first 12 hex of SHA256>_<count>".
# Anything else is not a duplicate group and is never touched.
$groupNamePattern = '^(?<hash>[0-9a-f]{12})_\d+$'


$allBuckets = @("RAW", "JPG", "VIDEO", "ELSE")
$buckets = if ($Stage -eq "ALL") { $allBuckets } else { @($Stage) }

Write-Host "Pruning duplicate groups..."
Write-Host "Started:         $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "DuplicatesRoot:  $DuplicatesRoot"
Write-Host "Stage:           $Stage"
Write-Host "Action:          $Action"
Write-Host "KeepRule:        $KeepRule"
Write-Host "WhatIf:          $WhatIf"
Write-Host "Log:             $logFile"

Start-RunLog $logFile
Write-LogLine "RUN`tstart=$runStart`tdupesRoot=$DuplicatesRoot`tstage=$Stage`taction=$Action`tkeepRule=$KeepRule`twhatif=$WhatIf"
Write-LogLine "PHASE`tname=scan_groups"

$rows = New-Object System.Collections.Generic.List[object]
$scannedModels = 0
$groupFolders = 0
$groupsWithDuplicates = 0
$groupsSingle = 0
$filesSeen = 0
$plannedDeletes = 0
$deletedFiles = 0
$skippedNotIdentical = 0
$skippedNotGroup = 0
$errors = 0
$bucketCount = 0

foreach ($bucket in $buckets) {
  $bucketPath = Join-Path $DuplicatesRoot $bucket
  if (-not (Test-Path -LiteralPath $bucketPath -PathType Container)) { continue }
  $bucketCount++

  $modelDirs = [System.IO.Directory]::EnumerateDirectories($bucketPath)
  foreach ($modelDir in $modelDirs) {
    $scannedModels++
    $groupDirs = [System.IO.Directory]::EnumerateDirectories($modelDir)

    foreach ($groupDir in $groupDirs) {
      $groupName = Split-Path -Leaf $groupDir
      if ($groupName -notmatch $groupNamePattern) {
        $skippedNotGroup++
        Write-LogLine "SKIP_NOT_GROUP`t$groupDir"
        continue
      }
      $groupFolders++
      $fileList = New-Object System.Collections.Generic.List[System.IO.FileInfo]
      foreach ($fp in [System.IO.Directory]::EnumerateFiles($groupDir)) {
        [void]$fileList.Add((Get-Item -LiteralPath $fp))
      }

      $count = $fileList.Count
      $filesSeen += $count

      if ($count -le 1) {
        $groupsSingle++
        continue
      }

      $groupsWithDuplicates++
      $keep = Select-KeepFile -Files $fileList -Rule $KeepRule
      # Hash of the file we keep; every delete candidate must match it exactly.
      $keepHash = $null
      try { $keepHash = Get-FileSha256 $keep.FullName }
      catch {
        $errors++
        $err = "ERROR`thash`t$($keep.FullName)`t$($_.Exception.Message)"
        Write-Warning $err
        Write-LogLine $err
        continue
      }
      $groupHashPrefix = [regex]::Match($groupName, $groupNamePattern).Groups['hash'].Value
      if (-not $keepHash.StartsWith($groupHashPrefix)) {
        # The folder no longer holds what Find-Duplicates put there: touch nothing.
        $skippedNotIdentical += ($count - 1)
        Write-LogLine "SKIP_GROUP_CHANGED`t$groupDir`tkeep=$($keep.FullName)"
        foreach ($f in $fileList) {
          $rows.Add([pscustomobject]@{
            Bucket   = $bucket
            Model    = (Split-Path -Leaf $modelDir)
            GroupId  = $groupName
            FilePath = $f.FullName
            FileSize = $f.Length
            Action   = "KeepGroupChanged"
          }) | Out-Null
        }
        continue
      }
      $setId = Split-Path -Leaf $groupDir
      $model = Split-Path -Leaf $modelDir

      foreach ($f in $fileList) {
        if ($f.FullName -eq $keep.FullName) {
          $rows.Add([pscustomobject]@{
            Bucket   = $bucket
            Model    = $model
            GroupId  = $setId
            FilePath = $f.FullName
            FileSize = $f.Length
            Action   = "Keep"
          }) | Out-Null
          Write-LogLine "KEEP`t$($f.FullName)"
          continue
        }

        # Safety: never delete a file unless it is byte-identical to the kept one.
        $identical = $false
        try {
          $identical = ($f.Length -eq $keep.Length) -and ((Get-FileSha256 $f.FullName) -eq $keepHash)
        }
        catch {
          $errors++
          $err = "ERROR`thash`t$($f.FullName)`t$($_.Exception.Message)"
          Write-Warning $err
          Write-LogLine $err
        }
        if (-not $identical) {
          $skippedNotIdentical++
          $rows.Add([pscustomobject]@{
            Bucket   = $bucket
            Model    = $model
            GroupId  = $setId
            FilePath = $f.FullName
            FileSize = $f.Length
            Action   = "KeepNotIdentical"
          }) | Out-Null
          Write-LogLine "SKIP_NOT_IDENTICAL`t$($f.FullName)`tkeep=$($keep.FullName)"
          continue
        }

        $plannedDeletes++
        $rows.Add([pscustomobject]@{
          Bucket   = $bucket
          Model    = $model
          GroupId  = $setId
          FilePath = $f.FullName
          FileSize = $f.Length
          Action   = if ($Action -eq "Delete") { "DeletePlanned" } else { "DeleteCandidate" }
        }) | Out-Null

        Write-LogLine "DELETE_PLANNED`t$($f.FullName)"

        if ($Action -eq "Delete") {
          try {
            if (-not $WhatIf) {
              Remove-Item -LiteralPath $f.FullName -Force
              $deletedFiles++
              # Written to disk immediately so an interrupted run still has a full record.
              Write-LogLine "DELETE_DONE`t$($f.FullName)`tsha256=$keepHash`tkept=$($keep.FullName)"
            }
          }
          catch {
            $errors++
            $err = "ERROR`t$($f.FullName)`t$($_.Exception.Message)"
            Write-Warning $err
            Write-LogLine $err
          }
        }
      }

      if (($groupFolders % 2500) -eq 0) {
        $elapsedNow = (Get-Date) - $runStart
        $rate = if ($elapsedNow.TotalSeconds -gt 0) { [math]::Round($groupFolders / $elapsedNow.TotalSeconds, 1) } else { 0 }
        Write-Host ("Progress: groups {0}, duplicate sets {1}, planned deletes {2} ({3} groups/s)" -f $groupFolders, $groupsWithDuplicates, $plannedDeletes, $rate)
        Write-LogLine "PROGRESS`tgroups=$groupFolders`tdupeSets=$groupsWithDuplicates`tplannedDeletes=$plannedDeletes`trate=$rate"
      }
    }
  }
}

$rows | Export-Csv -LiteralPath $reportCsv -NoTypeInformation -Encoding UTF8

$elapsed = (Get-Date) - $runStart
$summary = [ordered]@{
  runStarted            = $runStart.ToString("o")
  runEnded              = (Get-Date).ToString("o")
  duplicatesRoot        = $DuplicatesRoot
  stage                 = $Stage
  action                = $Action
  keepRule              = $KeepRule
  whatIf                = [bool]$WhatIf
  bucketsScanned        = $bucketCount
  modelFoldersScanned   = $scannedModels
  groupFoldersScanned   = $groupFolders
  duplicateSets         = $groupsWithDuplicates
  singleFileGroups      = $groupsSingle
  filesSeen             = $filesSeen
  plannedDeletes        = $plannedDeletes
  deletedFiles          = $deletedFiles
  skippedNotIdentical   = $skippedNotIdentical
  skippedNotGroupFolder = $skippedNotGroup
  errors                = $errors
  elapsedSeconds        = [math]::Round($elapsed.TotalSeconds, 2)
  reportCsv             = $reportCsv
  logFile               = $logFile
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
Write-LogLine "SUMMARY`tgroups=$groupFolders`tdupeSets=$groupsWithDuplicates`tplannedDeletes=$plannedDeletes`tdeleted=$deletedFiles`terrors=$errors"
Stop-RunLog

Write-Host ""
Write-Host "Done."
Write-Host "Buckets scanned:      $bucketCount"
Write-Host "Model folders:        $scannedModels"
Write-Host "Group folders:        $groupFolders"
Write-Host "Duplicate sets:       $groupsWithDuplicates"
Write-Host "Single-file groups:   $groupsSingle"
Write-Host "Files seen:           $filesSeen"
Write-Host "Planned deletes:      $plannedDeletes"
Write-Host "Deleted files:        $deletedFiles"
Write-Host "Not identical (kept): $skippedNotIdentical"
Write-Host "Non-group folders:    $skippedNotGroup"
Write-Host "Errors:               $errors"
Write-Host "CSV report:           $reportCsv"
Write-Host "Summary JSON:         $summaryJson"
Write-Host "Log:                  $logFile"
if ($errors -gt 0) { exit 3 }
