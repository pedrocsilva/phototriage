param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

# Fake ExifTool that returns missing, empty or hostile camera metadata,
# keyed by file name. Used by tests/Validate-Safety.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Args -contains "-ver") {
  "13.00-fake-edge"
  exit 0
}

$sourcePath = $Args[-1]
if (-not $sourcePath -or -not (Test-Path -LiteralPath $sourcePath)) {
  "[]"
  exit 0
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in (Get-ChildItem -LiteralPath $sourcePath -Recurse -File)) {
  $obj = [ordered]@{ SourceFile = $f.FullName }
  switch ($f.Name.ToLowerInvariant()) {
    "dotdot.jpg"      { $obj.Model = ".." }
    "dot.jpg"         { $obj.Model = "." }
    "traversal.jpg"   { $obj.Model = "../../escape" }
    "backslash.jpg"   { $obj.Model = "..\..\escape" }
    "blank.jpg"       { $obj.Model = "   " }
    "reserved.jpg"    { $obj.Model = "NUL" }
    "trailingdot.jpg" { $obj.Make = "Canon"; $obj.Model = "Canon EOS." }
    "emptystr.jpg"    { $obj.Make = ""; $obj.Model = "" }
    default           { } # no metadata at all
  }
  $rows.Add([pscustomobject]$obj) | Out-Null
}

$rows | ConvertTo-Json -Depth 4
