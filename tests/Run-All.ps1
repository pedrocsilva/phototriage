#Requires -Version 7.4
# Runs every tests/Validate-*.ps1 in its own PowerShell process and exits
# non-zero if any of them fails. Used locally and by CI.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$pwshExe = (Get-Process -Id $PID).Path
$tests = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "Validate-*.ps1" | Sort-Object Name
$results = New-Object System.Collections.Generic.List[object]

Write-Host "PowerShell $($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"

foreach ($t in $tests) {
  Write-Host ""
  Write-Host "=== $($t.Name)"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $pwshExe -NoProfile -File $t.FullName
  $code = $LASTEXITCODE
  $sw.Stop()
  $results.Add([pscustomobject]@{
    Test    = $t.Name
    Result  = if ($code -eq 0) { "PASS" } else { "FAIL (exit $code)" }
    Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  }) | Out-Null
}

Write-Host ""
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Result -ne "PASS" })
if ($failed.Count -gt 0) {
  Write-Host "$($failed.Count) of $($results.Count) test files failed." -ForegroundColor Red
  exit 1
}
Write-Host "All $($results.Count) test files passed." -ForegroundColor Green
