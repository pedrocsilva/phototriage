param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Args -contains "-ver") {
  "13.00-fake-posix"
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
  $obj = [ordered]@{
    SourceFile = ($f.FullName -replace '\\', '/')
  }

  switch -Wildcard ($name) {
    "img1.jpg" {
      $obj.Make = "Apple"
      $obj.Model = "iPhone 15 Pro Max"
    }
    "raw1.arw" {
      $obj.Make = "SONY"
      $obj.Model = "ILCE-7M4"
    }
    "clip1.mp4" {
      $obj.Make = "LGE"
      $obj.Model = "Nexus 5"
    }
    "scan1.png" {
    }
    "duplicate*.jpg" {
      $obj.Make = "Apple"
      $obj.Model = "iPhone 15 Pro Max"
    }
    default {
    }
  }

  $rows.Add([pscustomobject]$obj) | Out-Null
}

$rows | ConvertTo-Json -Depth 4
