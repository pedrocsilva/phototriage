#Requires -Version 7.4
# Shared helpers for the PhotoTriage scripts.
#
# Hot-path functions (called once per file) use .NET APIs directly instead of
# provider cmdlets such as Test-Path / Get-Item / Add-Content, which are 10-100x
# slower per call and dominate run time on archives with 100k+ files.

$script:IsWindowsHost = [System.IO.Path]::DirectorySeparatorChar -eq '\'
$script:PathComparison = if ($script:IsWindowsHost) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
$script:ReservedWindowsNames = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]@("CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"),
  [System.StringComparer]::OrdinalIgnoreCase)

# ------------------------------------------------------------------ buckets

# Single source of truth for which extensions go to which bucket.
$script:MediaBuckets = [ordered]@{
  RAW   = @("arw", "nef", "raf", "dng", "cr2", "orf", "gpr")
  JPG   = @("jpg", "jpeg", "heic")
  VIDEO = @("mov", "mp4", "mpg")
  ELSE  = @("tif", "tiff", "png", "gif")
}
$script:ExtToBucket = @{}   # PowerShell hashtables are case-insensitive
foreach ($b in $script:MediaBuckets.Keys) {
  foreach ($e in $script:MediaBuckets[$b]) { $script:ExtToBucket[$e] = $b }
}

# Bucket name for a file path or extension ("RAW", "JPG", ...), or $null.
function Get-MediaBucket([string]$PathOrExtension) {
  $ext = [System.IO.Path]::GetExtension($PathOrExtension)
  if (-not $ext) { $ext = $PathOrExtension }
  return $script:ExtToBucket[$ext.TrimStart('.')]
}

# "-ext jpg -ext jpeg ..." so ExifTool only opens files we can actually sort
# (skips sidecars, thumbnails, documents, ...).
function Get-ExifToolExtArgs([string]$Stage = "ALL") {
  $buckets = if ($Stage -eq "ALL") { @($script:MediaBuckets.Keys) } else { @($Stage) }
  $exifArgs = New-Object System.Collections.Generic.List[string]
  foreach ($b in $buckets) {
    foreach ($e in $script:MediaBuckets[$b]) { $exifArgs.Add("-ext"); $exifArgs.Add($e) }
  }
  return $exifArgs.ToArray()
}

# ------------------------------------------------------------------ names

# Camera id from one ExifTool JSON row: "Make Model" (unless Model already
# contains Make), then DeviceModelName, then AndroidModel, else "UNKNOWN".
function Get-CameraIdFromExif([object]$Item) {
  $model = "$($Item.Model)".Trim()
  if ($model) {
    $make = "$($Item.Make)".Trim()
    if ($make -and ($model -notmatch [regex]::Escape($make))) { return "$make $model" }
    return $model
  }
  $p = $Item.PSObject.Properties
  if ($p['DeviceModelName'] -and "$($Item.DeviceModelName)".Trim()) { return "$($Item.DeviceModelName)".Trim() }
  if ($p['AndroidModel'] -and "$($Item.AndroidModel)".Trim()) { return "$($Item.AndroidModel)".Trim() }
  return "UNKNOWN"
}

# Turns a camera/model string from EXIF into a safe single folder name.
# EXIF is untrusted input: it must never produce "..", "." or a path separator.
function Sanitize-Name([string]$name) {
  if ([string]::IsNullOrWhiteSpace($name)) { return "UNKNOWN" }
  $n = $name.Trim()
  $n = ($n -replace '[<>:"/\\|?*\x00-\x1F]', '_')
  $n = ($n -replace '\s+', ' ').Trim()
  if ($n.Length -gt 120) { $n = $n.Substring(0, 120) }
  # Windows silently drops trailing dots/spaces, "." / ".." are path traversal, and
  # a leading dot makes the folder hidden on macOS/Linux.
  $n = $n.Trim('.', ' ')
  if ($n -eq "" -or $n -eq "-") { return "UNKNOWN" }
  if ($script:ReservedWindowsNames.Contains($n)) { return "_$n" }
  return $n
}

# ------------------------------------------------------------------ paths

# Absolute, normalized path. Already-absolute paths are a pure string operation;
# relative ones resolve against PowerShell's location (not the .NET process cwd).
function Get-FullPath([string]$path) {
  if ([System.IO.Path]::IsPathFullyQualified($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  $p = if ($script:IsWindowsHost) { $path -replace '/', '\' } else { $path }
  return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p))
}

function Test-PathExists([string]$path) {
  return [System.IO.File]::Exists($path) -or [System.IO.Directory]::Exists($path)
}

$script:KnownDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
# Directories this process created. A new directory is always on its parent's
# volume, which lets the volume check skip a slow stat call for each of them.
$script:CreatedDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
function Ensure-Dir([string]$path) {
  $full = Get-FullPath $path
  if ($script:KnownDirs.Contains($full)) { return }
  if (-not [System.IO.Directory]::Exists($full)) {
    [void][System.IO.Directory]::CreateDirectory($full)
    [void]$script:CreatedDirs.Add($full.TrimEnd([System.IO.Path]::DirectorySeparatorChar))
  }
  [void]$script:KnownDirs.Add($full)
}

# Case-insensitive on every OS: macOS and Windows file systems usually are, and
# treating Linux the same way only means an extra "__1" in a rare corner case.
function New-ReservedPathSet {
  # Leading comma: PowerShell would otherwise unroll the empty set into $null.
  return , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
}

# A path that does not exist yet (and is not reserved earlier in this run),
# adding __1, __2, ... before the extension. Never returns an existing path.
function Get-UniqueTargetPath {
  param(
    [Parameter(Mandatory = $true)][string]$targetPath,
    [AllowNull()][System.Collections.Generic.HashSet[string]]$Reserved = $null
  )
  $candidate = $targetPath
  $i = 0
  while ((Test-PathExists $candidate) -or ($null -ne $Reserved -and $Reserved.Contains($candidate))) {
    $i++
    $dir = [System.IO.Path]::GetDirectoryName($targetPath)
    $name = "{0}__{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($targetPath), $i, [System.IO.Path]::GetExtension($targetPath)
    $candidate = if ($dir) { [System.IO.Path]::Combine($dir, $name) } else { $name }
  }
  if ($null -ne $Reserved) { [void]$Reserved.Add($candidate) }
  return $candidate
}

# ------------------------------------------------------------------ moving

# Volume id per directory, cached: a run touches few distinct directories.
$script:VolumeCache = @{}
function Get-VolumeId([string]$dir) {
  $dir = $dir.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
  if ($script:VolumeCache.ContainsKey($dir)) { return $script:VolumeCache[$dir] }
  if ($script:CreatedDirs.Contains($dir)) {
    $parent = [System.IO.Path]::GetDirectoryName($dir)
    if ($parent) { $id = Get-VolumeId $parent; $script:VolumeCache[$dir] = $id; return $id }
  }
  $id = $null
  try {
    if ($script:IsWindowsHost) {
      $id = [System.IO.Path]::GetPathRoot($dir).TrimEnd('\').ToUpperInvariant()   # "D:\" and "D:" alike
    }
    else {
      $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
      if ($item.PSObject.Properties['UnixStat'] -and $null -ne $item.UnixStat) { $id = "$($item.UnixStat.DeviceId)" }
    }
  }
  catch { $id = $null }
  $script:VolumeCache[$dir] = $id
  return $id
}

# Best-effort: unknown counts as "different", which selects the safe copy path.
function Test-SameVolume([string]$dirA, [string]$dirB) {
  $a = Get-VolumeId (Get-FullPath $dirA)
  $b = Get-VolumeId (Get-FullPath $dirB)
  return ($null -ne $a -and $a -eq $b)
}

# Moves one file without ever overwriting anything.
# - Same volume: a single rename, which is atomic (the file is either at the
#   source or at the target, even if the process is killed).
# - Different volumes: copy to "<target>.phototriage-partial", check the size, restore the
#   timestamp, rename to the final name, then delete the source. If interrupted,
#   the source is still intact and the only leftover is a clearly named
#   *.phototriage-partial file; the real target name is never left half-written. A kill
#   between the last two steps leaves an identical copy in both places (no loss).
# Set PHOTOTRIAGE_FORCE_COPY_MOVE=1 to force the copy path (used by the tests).
function Move-MediaFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Target
  )

  $src = Get-FullPath $Source
  $dst = Get-FullPath $Target
  if (-not [System.IO.File]::Exists($src)) { throw "Source file not found: $src" }
  if (Test-PathExists $dst) { throw "Refusing to overwrite existing target: $dst" }

  $dstDir = [System.IO.Path]::GetDirectoryName($dst)
  $forceCopy = [System.Environment]::GetEnvironmentVariable("PHOTOTRIAGE_FORCE_COPY_MOVE") -eq "1"

  if (-not $forceCopy -and (Test-SameVolume ([System.IO.Path]::GetDirectoryName($src)) $dstDir)) {
    # Two-argument File.Move throws if the target exists; it never overwrites.
    [System.IO.File]::Move($src, $dst)
    return
  }

  $srcInfo = [System.IO.FileInfo]::new($src)
  $partial = Get-UniqueTargetPath ("$dst.phototriage-partial")
  [System.IO.File]::Copy($src, $partial, $false)

  $copied = [System.IO.FileInfo]::new($partial)
  if ($copied.Length -ne $srcInfo.Length) {
    [System.IO.File]::Delete($partial)
    throw "Copy size mismatch for $src (source $($srcInfo.Length) bytes, copy $($copied.Length) bytes); source left untouched"
  }
  $copied.LastWriteTimeUtc = $srcInfo.LastWriteTimeUtc

  [System.IO.File]::Move($partial, $dst)
  [System.IO.File]::Delete($src)
}

# Removes empty directories below $RootPath, deepest first. A directory is only
# removed when it has no entries at all (hidden files included), and the
# non-recursive delete throws instead of removing anything that is not empty.
function Remove-EmptyDirectoryTree {
  param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [switch]$IncludeRoot
  )

  $root = Get-FullPath $RootPath
  if (-not [System.IO.Directory]::Exists($root)) { return 0 }

  $removed = 0
  $dirs = New-Object System.Collections.Generic.List[string]
  try {
    foreach ($d in [System.IO.Directory]::EnumerateDirectories($root, "*", [System.IO.SearchOption]::AllDirectories)) { $dirs.Add($d) }
  }
  catch { }
  $ordered = @($dirs | Sort-Object { $_.Length } -Descending)
  if ($IncludeRoot) { $ordered += $root }

  foreach ($d in $ordered) {
    try {
      if (-not [System.IO.Directory]::EnumerateFileSystemEntries($d).GetEnumerator().MoveNext()) {
        [System.IO.Directory]::Delete($d, $false)
        [void]$script:KnownDirs.Remove($d)
        $removed++
      }
    }
    catch {
      # Not empty, unreadable or already gone: leave it alone.
    }
  }
  return $removed
}

# ------------------------------------------------------------------ hashing

# SHA-256 as lowercase hex (as fast as Get-FileHash, without cmdlet overhead
# and with a sequential-read hint for large videos).
function Get-FileSha256([string]$Path) {
  $fs = [System.IO.FileStream]::new((Get-FullPath $Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read, 81920, [System.IO.FileOptions]::SequentialScan)
  try { return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($fs)).ToLowerInvariant() }
  finally { $fs.Dispose() }
}

# ------------------------------------------------------------------ logging

# Append-only UTF-8 writer that hands every line to the OS immediately (no
# buffering), so a killed process still leaves a complete log. Others can read
# the file while it is being written.
function Open-AppendWriter([string]$Path) {
  $full = Get-FullPath $Path
  Ensure-Dir ([System.IO.Path]::GetDirectoryName($full))
  $fs = [System.IO.FileStream]::new($full, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::ReadWrite, 1)
  $w = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
  $w.AutoFlush = $true
  return $w
}

$script:RunLog = $null
function Start-RunLog([string]$Path) {
  Stop-RunLog
  $script:RunLog = Open-AppendWriter $Path
}
function Write-LogLine([string]$Line) {
  if ($null -ne $script:RunLog) { $script:RunLog.WriteLine($Line) }
}
function Stop-RunLog {
  if ($null -ne $script:RunLog) {
    $script:RunLog.Dispose()
    $script:RunLog = $null
  }
}

# ------------------------------------------------------------------ exiftool

# Fails fast with a clear message when ExifTool is not available, instead of
# silently reporting "no files".
function Assert-ExifToolAvailable([string]$ExifTool) {
  if (-not (Get-Command $ExifTool -ErrorAction SilentlyContinue)) {
    throw "ExifTool not found: '$ExifTool'. Install it from https://exiftool.org or pass -ExifTool <path>."
  }
}

Export-ModuleMember -Function `
  Get-MediaBucket, Get-ExifToolExtArgs, Get-CameraIdFromExif, Sanitize-Name, `
  Get-FullPath, Test-PathExists, Ensure-Dir, New-ReservedPathSet, Get-UniqueTargetPath, `
  Test-SameVolume, Move-MediaFile, Remove-EmptyDirectoryTree, Get-FileSha256, `
  Start-RunLog, Write-LogLine, Stop-RunLog, Assert-ExifToolAvailable
