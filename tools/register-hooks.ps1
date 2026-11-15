<#
.SYNOPSIS
  Registers the shared hooks on this machine. Run it on every machine, and again whenever
  ~/.claude/hooks/hooks.json changes (that manifest syncs; settings.json does not).
    register-hooks.ps1 [-PersonalMemory] [-InstallPython]
  -PersonalMemory : also load ~/.claude/personal-memory/MEMORY.md (notes kept on this machine only).
  -InstallPython  : install Python 3.12 for this user with winget if no Python is found.
  Only entries made by this script are replaced; your other settings and hooks stay untouched.
#>
param(
    [string]$HomeRoot,
    [switch]$PersonalMemory,
    [switch]$InstallPython,
    [string]$SettingsPath,
    [switch]$DryRun     # show the hooks section that would be saved; change nothing
)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
if (-not $SettingsPath) { $SettingsPath = Join-Path $P.Config 'settings.json' }

$py = Find-Python
if (-not $py -and $DryRun) { $py = 'C:\<python>\python.exe'; Write-Host 'No Python found; the dry run uses a placeholder path.' -ForegroundColor Yellow }
if (-not $py -and $InstallPython) {
    winget install -e --id Python.Python.3.12 --source winget --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
    $py = Find-Python
}
if (-not $py) { throw 'No Python found. Install Python 3 (or run again with -InstallPython). Hooks need it.' }
Write-Host "Python: $py"

# Local copies of the launcher and the personal-memory hook (config root does not sync).
if (-not $DryRun) { foreach ($f in 'run_shared_hook.py', 'personal_memory_hook.py') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $P.Config $f) -Force } }

$manifestPath = Join-Path $P.Config 'hooks\hooks.json'
$entries = @()
if (Test-Path -LiteralPath $manifestPath) {
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($m.hooks | Where-Object { $_ -and $_.name -and $_.event })
}
$pyFwd  = $py -replace '\\', '/'
$cfgFwd = $P.Config -replace '\\', '/'
function New-Cmd($name) { "`"$pyFwd`" -B `"$cfgFwd/run_shared_hook.py`" $name" }

$settings = if (Test-Path -LiteralPath $SettingsPath) { Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
$H = $settings.hooks

# Drop entries this script made before, keep everything else.
foreach ($ev in @($H.PSObject.Properties | ForEach-Object { $_.Name })) {
    $keep = @($H.$ev | Where-Object {
        $cmds = @($_.hooks | ForEach-Object { $_.command })
        -not ($cmds | Where-Object { $_ -match 'run_shared_hook\.py|personal_memory_hook\.py' })
    })
    if ($keep.Count) { $H.$ev = $keep } else { $H.PSObject.Properties.Remove($ev) }
}
function Add-Entry($ev, $matcher, $cmd, $timeout) {
    $e = [ordered]@{}
    if ($matcher) { $e.matcher = $matcher }
    $e.hooks = @([ordered]@{ type = 'command'; command = $cmd; timeout = $timeout })
    if ($H.PSObject.Properties[$ev]) { $H.$ev = @($H.$ev) + [pscustomobject]$e }
    else { $H | Add-Member -NotePropertyName $ev -NotePropertyValue @([pscustomobject]$e) }
}
foreach ($e in $entries) {
    $t = if ($e.timeout) { [int]$e.timeout } else { 30 }
    Add-Entry $e.event $e.matcher (New-Cmd $e.name) $t
    Write-Host "  hook   $($e.event) $($e.matcher) -> $($e.name)"
}
if ($PersonalMemory) {
    $pm = Join-Path $P.Config 'personal-memory\MEMORY.md'
    if (-not $DryRun -and -not (Test-Path -LiteralPath $pm)) { Write-Utf8 $pm "# Personal memory (this machine only)`n" }
    Add-Entry 'SessionStart' $null "`"$pyFwd`" -B `"$cfgFwd/personal_memory_hook.py`"" 15
    Write-Host '  hook   SessionStart -> personal memory'
}
if (-not @($H.PSObject.Properties).Count) { $settings.PSObject.Properties.Remove('hooks') }

if ($DryRun) {
    Write-Host "DRY RUN: $SettingsPath would get this hooks section (other settings unchanged):" -ForegroundColor Yellow
    if ($settings.PSObject.Properties['hooks']) { $settings.hooks | ConvertTo-Json -Depth 20 } else { '(no hooks)' }
    return
}
if (Test-Path -LiteralPath $SettingsPath) { Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
Write-Utf8 $SettingsPath ($settings | ConvertTo-Json -Depth 20)
Write-Host "Saved $SettingsPath ($($entries.Count) shared hook(s)$(if ($PersonalMemory) {', personal memory'}))."
Write-Host 'Hooks take effect in new sessions.'
