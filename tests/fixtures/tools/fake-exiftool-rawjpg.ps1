Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$arguments = @($args)

if (($arguments -contains "-ver") -or ($arguments -contains "ver")) {
  "13.00-fake-rawjpg"
  exit 0
}

if (-not $arguments -or $arguments.Count -eq 0) {
  "[]"
  exit 0
}

$sourcePaths = @($arguments | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
if ($sourcePaths.Count -eq 0) {
  "[]"
  exit 0
}

$files = @()
foreach ($p in $sourcePaths) {
  $files += Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue
}
$rows = New-Object System.Collections.Generic.List[object]

foreach ($f in $files) {
  $name = $f.Name.ToLowerInvariant()
  $ext = $f.Extension.TrimStart('.').ToLowerInvariant()
  $obj = [ordered]@{
    SourceFile        = $f.FullName
    FileTypeExtension = $ext
    FileName          = $f.Name
  }

  switch ($name) {
    "img_0001.arw" {
      $obj.DateTimeOriginal = "2024:01:01 10:00:00"
      $obj.RawImageWidth = 6000
      $obj.RawImageHeight = 4000
    }
    "img_0001.jpg" {
      $obj.DateTimeOriginal = "2024:01:01 10:00:00"
      $obj.ImageWidth = 5000
      $obj.ImageHeight = 3333
    }
    "img_0002.arw" {
      $obj.DateTimeOriginal = "2024:01:01 10:00:05"
      $obj.RawImageWidth = 2000
      $obj.RawImageHeight = 1333
    }
    "img_0002.jpg" {
      $obj.DateTimeOriginal = "2024:01:01 10:00:06"
      $obj.ImageWidth = 6000
      $obj.ImageHeight = 4000
    }
    "img_9999.jpg" {
      $obj.DateTimeOriginal = "2024:01:01 13:00:00"
      $obj.ImageWidth = 4000
      $obj.ImageHeight = 3000
    }
    default {
    }
  }

  $rows.Add([pscustomobject]$obj) | Out-Null
}

$rows | ConvertTo-Json -Depth 4
