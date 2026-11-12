<#
.SYNOPSIS
  Summarizes a folder before you sort it: file count and size per extension,
  and which bucket Reorg-Media would put each extension in. Read only; does not
  need ExifTool.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$Path
)

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking

$root = Get-FullPath $Path
if (-not [IO.Directory]::Exists($root)) { Write-Error "Folder not found: $root"; exit 2 }

$opts = [IO.EnumerationOptions]::new()
$opts.RecurseSubdirectories = $true
$opts.IgnoreInaccessible = $true
$opts.AttributesToSkip = [IO.FileAttributes]::None   # include hidden files

$stats = @{}
$totalFiles = 0; $totalBytes = [long]0
foreach ($f in [IO.DirectoryInfo]::new($root).EnumerateFiles("*", $opts)) {
  $ext = $f.Extension.ToLowerInvariant()
  if (-not $stats.ContainsKey($ext)) { $stats[$ext] = [long[]]@(0, 0) }
  $stats[$ext][0]++; $stats[$ext][1] += $f.Length
  $totalFiles++; $totalBytes += $f.Length
}

function Format-Size([long]$b) {
  if ($b -ge 1TB) { return "{0:N2} TB" -f ($b / 1TB) }
  if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
  if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
  return "{0:N0} KB" -f [math]::Ceiling($b / 1KB)
}

$rows = $stats.GetEnumerator() | ForEach-Object {
  $bucket = if ($_.Key) { Get-MediaBucket $_.Key } else { $null }
  [pscustomobject]@{
    Extension = if ($_.Key) { $_.Key } else { "(none)" }
    Files     = $_.Value[0]
    Size      = Format-Size $_.Value[1]
    Bucket    = if ($bucket) { $bucket } else { "(not sorted)" }
    Bytes     = $_.Value[1]
  }
} | Sort-Object Files -Descending

$rows | Format-Table Extension, Files, Size, Bucket -AutoSize
$sorted = @($rows | Where-Object { $_.Bucket -ne "(not sorted)" })
$sortedFiles = ($sorted | Measure-Object Files -Sum).Sum
Write-Host ("Total: {0:N0} files, {1}. Reorg-Media would sort {2:N0} of them; the rest stay where they are." -f $totalFiles, (Format-Size $totalBytes), [long]$sortedFiles)
