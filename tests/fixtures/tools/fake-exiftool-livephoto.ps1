param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Args -contains "-ver") {
  "13.00-fake-livephoto"
  exit 0
}

if (-not $Args -or $Args.Count -eq 0) {
  "[]"
  exit 0
}

$sourcePath = $Args[-1]
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
    SourceFile = $f.FullName
    FileTypeExtension = $ext
  }

  switch ($name) {
    "img_1001.heic" {
      $obj.Make = "Apple"
      $obj.Model = "iPhone 14 Pro"
      $obj.DateTimeOriginal = "2024:01:02 10:11:12"
      $obj.ContentIdentifier = "cid-1001"
    }
    "img_1001.mov" {
      $obj.Make = "Apple"
      $obj.Model = "iPhone 14 Pro"
      $obj.MediaCreateDate = "2024:01:02 10:11:13"
      $obj.ContentIdentifier = "cid-1001"
    }
    "001_img_2001.jpg" {
      $obj.Make = "Apple"
      $obj.Model = "iPhone 12 Pro"
      $obj.DateTimeOriginal = "2024:02:03 12:00:00"
    }
    "002_img_2001.mov" {
      $obj.Make = "Apple"
      $obj.Model = "iPhone 12 Pro"
      $obj.MediaCreateDate = "2024:02:03 12:00:01"
    }
    "img_3001.jpg" {
      $obj.Make = "Apple"
      $obj.Model = "iPhone 12 Pro"
      $obj.DateTimeOriginal = "2024:03:03 09:00:00"
    }
    "random.mov" {
      $obj.Make = "GoPro"
      $obj.Model = "HERO5 Black"
      $obj.MediaCreateDate = "2024:03:03 09:00:02"
    }
    default {
    }
  }

  $rows.Add([pscustomobject]$obj) | Out-Null
}

$rows | ConvertTo-Json -Depth 4
