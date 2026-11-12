Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$arguments = @($args)

if (($arguments -contains "-ver") -or ($arguments -contains "ver")) {
  "13.00-fake-rawformat"
  exit 0
}

if (-not $arguments -or $arguments.Count -eq 0) {
  "[]"
  exit 0
}

$sourcePath = $arguments | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Last 1
if (-not $sourcePath -or -not (Test-Path -LiteralPath $sourcePath)) {
  "[]"
  exit 0
}

$files = Get-ChildItem -LiteralPath $sourcePath -Recurse -File -ErrorAction SilentlyContinue
$rows = New-Object System.Collections.Generic.List[object]

foreach ($f in $files) {
  $name = $f.Name.ToLowerInvariant()
  $ext = $f.Extension.TrimStart('.').ToLowerInvariant()
  $obj = [ordered]@{
    SourceFile             = $f.FullName
    FileTypeExtension      = $ext
    FileName               = $f.Name
    Model                  = "X-T30"
    SerialNumber           = "TESTSERIAL01"
    InternalSerialNumber   = "TESTINTERNAL0001"
    LensModel              = "XF35mmF2 R WR"
    RawImageWidth          = 6276
    RawImageHeight         = 4140
  }

  switch ($name) {
    "same_001.raf" {
      $obj.DateTimeOriginal = "2024:05:01 12:00:00"
    }
    "same_001.dng" {
      $obj.DateTimeOriginal = "2024:05:01 12:00:00"
    }
    "solo_001.raf" {
      $obj.DateTimeOriginal = "2024:05:01 12:05:27"
    }
    "solo_002.dng" {
      $obj.DateTimeOriginal = "2024:05:01 12:05:32"
    }
    default {
      $obj.DateTimeOriginal = "2024:05:01 12:55:27"
    }
  }

  $rows.Add([pscustomobject]$obj) | Out-Null
}

$rows | ConvertTo-Json -Depth 5
