param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

# Fake ExifTool that prints truncated, invalid JSON (e.g. a crashed or killed
# exiftool process). Used by tests/Validate-Safety.ps1.

if ($Args -contains "-ver") {
  "13.00-fake-badjson"
  exit 0
}

'[{"SourceFile": "C:/somewhere/img1.jpg", "Make": "Apple", "Mod'
