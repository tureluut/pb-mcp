# lint_encoding.ps1 - enforce the project source-encoding rule.
#
# The plan offered: ASCII-only OR UTF-8 with BOM. The user elected the
# BOM branch. Evidence (frozen): BOM-less UTF-8 sources are silently misread
# as CP-1252 by both PB 5.73 and 6.40 (mcp-pb-spike-640/out_goodcheck.txt).
# Rule: every src/*.pb must start with a UTF-8 BOM (EF BB BF).
$root = Join-Path $PSScriptRoot '..\src'
$fail = $false
Get-ChildItem -Path $root -Filter *.pb | ForEach-Object {
  $b = [System.IO.File]::ReadAllBytes($_.FullName)
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
    Write-Host ("  OK   {0}" -f $_.Name)
  } else {
    Write-Host ("  FAIL {0} - missing UTF-8 BOM (BOM-less UTF-8 mojibakes on the PB compilers)" -f $_.Name)
    $fail = $true
  }
}
if ($fail) { exit 1 } else { exit 0 }
