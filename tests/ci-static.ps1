<#
.SYNOPSIS
  Quick checks on a built kit, no network and no install: every PowerShell script parses in the shell
  running this file, every JSON file reads, every Python file compiles, Setup.cmd keeps CRLF line ends.
    powershell -File tests\ci-static.ps1 [-Kit <kit folder>]
#>
param([string]$Kit = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$fails = 0
function Ok($cond, $what) {
    if ($cond) { Write-Host "PASS  $what" -ForegroundColor Green } else { $script:fails++; Write-Host "FAIL  $what" -ForegroundColor Red }
}
$files = Get-ChildItem -LiteralPath $Kit -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' }

foreach ($f in $files | Where-Object Extension -eq '.ps1') {
    $tok = $null; $err = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
    Ok (-not $err) "parses ($($PSVersionTable.PSVersion.Major).x): $($f.Name)"
    if ($err) { $err | ForEach-Object { Write-Host "      $($_.Extent.StartLineNumber): $($_.Message)" } }
}
foreach ($f in $files | Where-Object Extension -eq '.json') {
    $okJson = $true
    try { $null = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { $okJson = $false; Write-Host "      $_" }
    Ok $okJson "valid JSON: $($f.FullName.Substring($Kit.Length + 1))"
}
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if ($py) {
    foreach ($f in $files | Where-Object Extension -eq '.py') {
        & $py -B -c "import sys; compile(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1], 'exec')" $f.FullName
        Ok ($LASTEXITCODE -eq 0) "compiles: $($f.Name)"
    }
} else { Write-Host 'INFO  python not found: Python files skipped' }
$cmd = Join-Path $Kit 'Setup.cmd'
if (Test-Path -LiteralPath $cmd) {
    $raw = [IO.File]::ReadAllText($cmd)
    Ok ($raw -match "`r`n" -and $raw -notmatch "[^`r]`n") 'Setup.cmd has CRLF line ends'
}
Write-Host "`nStatic checks: $fails failure(s)." -ForegroundColor $(if ($fails) { 'Red' } else { 'Green' })
if ($fails) { exit 1 }
