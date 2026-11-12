<#
.SYNOPSIS
  Finds byte-identical files (same size, then SHA-256) within each Bucket/Camera folder.
  -Action MoveGroups moves each duplicate set into DuplicatesRoot/<Bucket>/<Camera>/<hash12>_<count>/
  for review. Default: report only.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$DestRoot,
  [Parameter(Mandatory = $true)][string]$DuplicatesRoot,
  [ValidateSet("RAW", "JPG", "VIDEO", "ELSE", "ALL")] [string]$Stage = "ALL",
  [ValidateSet("PerModelAndBucket")] [string]$Scope = "PerModelAndBucket",
  [ValidateSet("Report", "MoveGroups")] [string]$Action = "Report",
  [switch]$WhatIf
)

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking

$runStart = Get-Date
Ensure-Dir $DestRoot
Ensure-Dir $DuplicatesRoot
Ensure-Dir (Join-Path $DestRoot "_logs")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$logFile = Join-Path $DestRoot "_logs/dupes_groups_$stamp.log"
$manifestCsv = Join-Path $DestRoot "_logs/dupes_groups_$stamp.manifest.csv"
$modelSummaryCsv = Join-Path $DestRoot "_logs/dupes_groups_$stamp.models.csv"
$summaryJson = Join-Path $DestRoot "_logs/dupes_groups_$stamp.summary.json"

$allBuckets = @("RAW", "JPG", "VIDEO", "ELSE")
$buckets = if ($Stage -eq "ALL") { $allBuckets } else { @($Stage) }

Write-Host "Finding duplicate groups (optimized)..."
Write-Host "Started:         $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "DestRoot:        $DestRoot"
Write-Host "DuplicatesRoot:  $DuplicatesRoot"
Write-Host "Stage:           $Stage"
Write-Host "Scope:           $Scope"
Write-Host "Action:          $Action"
Write-Host "WhatIf:          $WhatIf"
Write-Host "Log:             $logFile"
# Ensure log exists immediately, even if run fails early.
Start-RunLog $logFile
Write-LogLine "RUN`tstart=$runStart`tdestRoot=$DestRoot`tdupesRoot=$DuplicatesRoot`tstage=$Stage`tscope=$Scope`taction=$Action`twhatif=$WhatIf"
Write-LogLine "PHASE`tname=scan_files"

$files = New-Object System.Collections.Generic.List[object]
$scanCount = 0
foreach ($bucket in $buckets) {
  $bucketPath = Join-Path $DestRoot $bucket
  if (-not (Test-Path -LiteralPath $bucketPath)) { continue }

  Get-ChildItem -LiteralPath $bucketPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      $_.FullName -notmatch '[\\/]_dupes_review([\\/]|$)' -and
      $_.FullName -notmatch '[\\/]_logs([\\/]|$)'
    } |
    ForEach-Object {
      [void]$files.Add($_)
      $scanCount++
      if (($scanCount % 10000) -eq 0) {
        $elapsedNow = (Get-Date) - $runStart
        $rate = if ($elapsedNow.TotalSeconds -gt 0) { [math]::Round($scanCount / $elapsedNow.TotalSeconds, 1) } else { 0 }
        Write-Host ("Scan progress: {0} files ({1} files/s)" -f $scanCount, $rate)
        Write-LogLine "PROGRESS`tphase=scan_files`tcount=$scanCount`trate=$rate"
      }
    }
}

if ($files.Count -eq 0) {
  Write-Host "No files found in selected buckets."
  Stop-RunLog
  exit 0
}

# Performance strategy:
# 1) Candidate pre-group by scope + size + extension (cheap).
# 2) Hash only files in candidate groups with 2+ entries (expensive).
Write-LogLine "PHASE`tname=build_candidates"
$candidateMap = @{}
$candidateRowCount = 0
foreach ($f in $files) {
  $modelDir = Split-Path -Parent $f.FullName
  $bucketDir = Split-Path -Parent $modelDir
  $bucket = Split-Path -Leaf $bucketDir
  $model = Split-Path -Leaf $modelDir
  if (-not $bucket -or -not $model) { continue }

  $scopeKey = "$bucket\$model"
  $ext = [IO.Path]::GetExtension($f.FullName).ToLowerInvariant()
  $candidateKey = "{0}|{1}" -f $f.Length, $ext

  $row = [pscustomobject]@{
    FilePath      = $f.FullName
    FileName      = $f.Name
    Size          = $f.Length
    LastWriteUtc  = $f.LastWriteTimeUtc
    Bucket        = $bucket
    Model         = $model
    ScopeKey      = $scopeKey
    CandidateKey  = $candidateKey
  }

  $candidateMapKey = "$scopeKey|$candidateKey"
  if (-not $candidateMap.ContainsKey($candidateMapKey)) {
    $candidateMap[$candidateMapKey] = New-Object System.Collections.Generic.List[object]
  }
  [void]$candidateMap[$candidateMapKey].Add($row)

  $candidateRowCount++
  if (($candidateRowCount % 15000) -eq 0) {
    Write-Host ("Candidate build progress: {0}/{1}" -f $candidateRowCount, $files.Count)
    Write-LogLine "PROGRESS`tphase=build_candidates`tcount=$candidateRowCount`tfiles=$($files.Count)"
  }
}

Write-LogLine "PHASE`tname=group_candidates"
$candidateGroups = @($candidateMap.Values | Where-Object { $_.Count -gt 1 })
Write-Host ("Candidate groups ready: {0}" -f $candidateGroups.Count)
Write-LogLine "INFO`tcandidateGroups=$($candidateGroups.Count)"
$hashComputed = 0
$dupeSets = New-Object System.Collections.Generic.List[object]

Write-LogLine "PHASE`tname=hash_candidates"
$groupIdx = 0
$hashErrors = 0
foreach ($cg in $candidateGroups) {
  $groupIdx++
  $hashed = foreach ($r in $cg) {
    try { $h = Get-FileSha256 $r.FilePath }
    catch {
      # Unreadable files are never grouped (a missing hash must not look like a match).
      $hashErrors++
      Write-LogLine "ERROR`thash`t$($r.FilePath)`t$($_.Exception.Message)"
      continue
    }
    $hashComputed++
    if (($hashComputed % 10000) -eq 0) {
      $elapsedNow = (Get-Date) - $runStart
      $rate = if ($elapsedNow.TotalSeconds -gt 0) { [math]::Round($hashComputed / $elapsedNow.TotalSeconds, 1) } else { 0 }
      Write-Host ("Hash progress: {0} files ({1} files/s), groups {2}/{3}" -f $hashComputed, $rate, $groupIdx, $candidateGroups.Count)
      Write-LogLine "PROGRESS`tphase=hash_candidates`thashed=$hashComputed`trate=$rate`tgroupIndex=$groupIdx`tgroupTotal=$($candidateGroups.Count)"
    }
    [pscustomobject]@{ Row = $r; Hash = $h }
  }

  $hashGroups = @($hashed) | Group-Object Hash | Where-Object { $_.Count -gt 1 }
  foreach ($hg in $hashGroups) {
    $sorted = $hg.Group | Sort-Object { $_.Row.LastWriteUtc }, { $_.Row.FilePath }
    $setRows = $sorted | ForEach-Object { $_.Row }

    $dupeSets.Add([pscustomobject]@{
      Bucket = $setRows[0].Bucket
      Model = $setRows[0].Model
      Hash = $hg.Name
      Files = @($setRows)
    }) | Out-Null
  }
}

$manifestRows = New-Object System.Collections.Generic.List[object]
$modelTouched = @{}
$movedFiles = 0
$errors = 0
$missingSource = 0
$plannedMoves = 0

if ($Action -eq "MoveGroups" -and $dupeSets.Count -gt 0) {
  Write-LogLine "PHASE`tname=move_groups"
  $setIdx = 0
  foreach ($set in $dupeSets) {
    $setIdx++
    $bucket = $set.Bucket
    $model = $set.Model
    $hashShort = $set.Hash.Substring(0, 12).ToLowerInvariant()
    $groupId = "{0}_{1}" -f $hashShort, $set.Files.Count

    $groupDir = Join-Path (Join-Path (Join-Path $DuplicatesRoot $bucket) $model) $groupId
    if (-not $WhatIf) { Ensure-Dir $groupDir }

    $modelKey = "$bucket\$model"
    if (-not $modelTouched.ContainsKey($modelKey)) { $modelTouched[$modelKey] = 0 }
    $modelTouched[$modelKey]++

    $idx = 0
    foreach ($row in $set.Files) {
      $idx++
      $src = $row.FilePath
      if (-not (Test-Path -LiteralPath $src)) {
        $missingSource++
        Write-LogLine "SKIP_MISSING`t$src"
        continue
      }

      $leaf = Split-Path -Leaf $src
      $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
      $ext = [IO.Path]::GetExtension($leaf)
      $preferred = "{0:000}_{1}{2}" -f $idx, $base, $ext
      $target = Get-UniqueTargetPath (Join-Path $groupDir $preferred)

      $plannedMoves++
      Write-LogLine "MOVE_PLANNED`t$src`t->`t$target"

      try {
        if ($WhatIf) {
          if (($plannedMoves % 5000) -eq 0) {
            Write-Host ("WhatIf move plan progress: {0} planned, sets {1}/{2}" -f $plannedMoves, $setIdx, $dupeSets.Count)
            Write-LogLine "PROGRESS`tphase=move_groups_whatif`tplanned=$plannedMoves`tsetIndex=$setIdx`tsetTotal=$($dupeSets.Count)"
          }
        }
        else {
          Move-MediaFile -Source $src -Target $target
          $movedFiles++
          Write-LogLine "MOVE_DONE`t$src`t->`t$target"
          if (($movedFiles % 5000) -eq 0) {
            $elapsedNow = (Get-Date) - $runStart
            $rate = if ($elapsedNow.TotalSeconds -gt 0) { [math]::Round($movedFiles / $elapsedNow.TotalSeconds, 1) } else { 0 }
            Write-Host ("Move progress: {0} moved ({1} files/s), sets {2}/{3}" -f $movedFiles, $rate, $setIdx, $dupeSets.Count)
            Write-LogLine "PROGRESS`tphase=move_groups`tmoved=$movedFiles`trate=$rate`tsetIndex=$setIdx`tsetTotal=$($dupeSets.Count)"
          }
        }
      }
      catch {
        $errors++
        $err = "ERROR`t$src`t$($_.Exception.Message)"
        Write-LogLine $err
        Write-Warning $err
      }

      $manifestRows.Add([pscustomobject]@{
        GroupId         = $groupId
        Hash            = $set.Hash
        Bucket          = $bucket
        Model           = $model
        OriginalPath    = $src
        GroupPath       = $target
        LastWriteUtc    = $row.LastWriteUtc
        FileSize        = $row.Size
      }) | Out-Null
    }
  }
}
else {
  Write-LogLine "PHASE`tname=report_only"
  foreach ($set in $dupeSets) {
    $hashShort = $set.Hash.Substring(0, 12).ToLowerInvariant()
    $groupId = "{0}_{1}" -f $hashShort, $set.Files.Count
    foreach ($row in $set.Files) {
      $manifestRows.Add([pscustomobject]@{
        GroupId         = $groupId
        Hash            = $set.Hash
        Bucket          = $set.Bucket
        Model           = $set.Model
        OriginalPath    = $row.FilePath
        GroupPath       = ""
        LastWriteUtc    = $row.LastWriteUtc
        FileSize        = $row.Size
      }) | Out-Null
    }
  }
}

$manifestRows | Export-Csv -LiteralPath $manifestCsv -NoTypeInformation -Encoding UTF8

$modelRows = New-Object System.Collections.Generic.List[object]
foreach ($k in ($modelTouched.Keys | Sort-Object)) {
  $parts = $k -split '\\'
  $modelRows.Add([pscustomobject]@{
    Bucket = $parts[0]
    Model = $parts[1]
    GroupsCreated = $modelTouched[$k]
  }) | Out-Null
}
$modelRows | Export-Csv -LiteralPath $modelSummaryCsv -NoTypeInformation -Encoding UTF8

$elapsed = (Get-Date) - $runStart
$summary = [ordered]@{
  runStarted            = $runStart.ToString("o")
  runEnded              = (Get-Date).ToString("o")
  destRoot              = $DestRoot
  duplicatesRoot        = $DuplicatesRoot
  stage                 = $Stage
  scope                 = $Scope
  action                = $Action
  whatIf                = [bool]$WhatIf
  scannedFiles          = $files.Count
  candidateGroups       = $candidateGroups.Count
  hashComputed          = $hashComputed
  duplicateSets         = $dupeSets.Count
  manifestRows          = $manifestRows.Count
  groupsCreated         = ($modelRows | Measure-Object -Property GroupsCreated -Sum).Sum
  modelFoldersTouched   = $modelRows.Count
  plannedMoves          = $plannedMoves
  movedFiles            = $movedFiles
  missingSource         = $missingSource
  errors                = $errors
  hashErrors            = $hashErrors
  elapsedSeconds        = [math]::Round($elapsed.TotalSeconds, 2)
  manifestCsv           = $manifestCsv
  modelSummaryCsv       = $modelSummaryCsv
  logFile               = $logFile
}

$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
Write-LogLine "SUMMARY`tscannedFiles=$($files.Count)`tcandidateGroups=$($candidateGroups.Count)`thashComputed=$hashComputed`tduplicateSets=$($dupeSets.Count)`tplannedMoves=$plannedMoves`tmovedFiles=$movedFiles`tmissingSource=$missingSource`terrors=$errors"
Stop-RunLog

Write-Host ""
Write-Host "Done."
Write-Host "Scanned files:        $($files.Count)"
Write-Host "Candidate groups:     $($candidateGroups.Count)"
Write-Host "Hash computed:        $hashComputed"
Write-Host "Duplicate sets:       $($dupeSets.Count)"
Write-Host "Model folders touched:$($modelRows.Count)"
Write-Host "Planned moves:        $plannedMoves"
Write-Host "Moved files:          $movedFiles"
Write-Host "Missing source:       $missingSource"
Write-Host "Errors:               $errors"
Write-Host "Manifest CSV:         $manifestCsv"
Write-Host "Model summary CSV:    $modelSummaryCsv"
Write-Host "Summary JSON:         $summaryJson"
Write-Host "Log:                  $logFile"
if ($errors -gt 0) { exit 3 }
