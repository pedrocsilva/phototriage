<#
.SYNOPSIS
  Lists the cameras found in EXIF, with file counts and the folder name each
  one maps to through modules/ModelMap.ps1. Read only.
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$ExifTool = "exiftool"
)

Import-Module (Join-Path $PSScriptRoot "../modules/PhotoTriage.psm1") -Force -DisableNameChecking
. (Join-Path $PSScriptRoot "../modules/ModelMap.ps1")

try { Assert-ExifToolAvailable $ExifTool }
catch { Write-Error $_.Exception.Message; exit 2 }

$exifArgs = @("-q", "-q", "-m", "-j", "-r") + (Get-ExifToolExtArgs "ALL") + @("-Make", "-Model", "-DeviceModelName", "-AndroidModel", "--", (Get-FullPath $Path))
$json = & $ExifTool @exifArgs 2>$null
if (-not $json) {
  Write-Host "No media files found."
  exit 0
}

$counts = @{}
foreach ($item in @([string]::Join("`n", @($json)) | ConvertFrom-Json)) {
  $id = Get-CameraIdFromExif $item
  if ($counts.ContainsKey($id)) { $counts[$id]++ } else { $counts[$id] = 1 }
}

$counts.GetEnumerator() | ForEach-Object {
  $folder = if ($script:ModelMap.ContainsKey($_.Key)) { $script:ModelMap[$_.Key] } else { $_.Key }
  [pscustomobject]@{
    Files    = $_.Value
    ExifName = $_.Key
    Folder   = Sanitize-Name $folder
    Mapped   = $script:ModelMap.ContainsKey($_.Key)
  }
} | Sort-Object Files -Descending | Format-Table -AutoSize
