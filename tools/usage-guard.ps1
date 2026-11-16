<#
.SYNOPSIS
  Optional plan-usage warnings for this machine: on, off or status.
    usage-guard.ps1 -On  [-Warn 80] [-Prepare 90] [-Handoff 95]
    usage-guard.ps1 -Off
    usage-guard.ps1          # status only, changes nothing
  -On copies the mod to this machine (it does not sync) and adds one line to the env block of
  ~/.claude/settings.json. -Off removes that line and the copy. Other settings are kept; settings.json
  is backed up before every change. Needs a recent engine (desktop app, or run "update" in the CLI).
  Warn / Prepare: a notice and a suggestion to get ready. Handoff: the assistant writes a handoff.
#>
param(
    [switch]$On,
    [switch]$Off,
    [ValidateRange(1, 100)][int]$Warn = 80,
    [ValidateRange(1, 100)][int]$Prepare = 90,
    [ValidateRange(1, 100)][int]$Handoff = 95,
    [string]$HomeRoot,
    [string]$SettingsPath,
    [switch]$DryRun
)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
if (-not $SettingsPath) { $SettingsPath = Join-Path $P.Config 'settings.json' }
$Key = 'CLAUDE_CODE_PLUGIN_DIRS'
$Src = Join-Path $PSScriptRoot 'usage-guard'
$Dst = Join-Path $P.State 'usage-guard'
$DstFwd = $Dst -replace '\\', '/'
$LevelsRx = 'const WARN = \d+, PREPARE = \d+, HANDOFF = \d+'

if ($On -and $Off) { throw 'Use -On or -Off, not both.' }
if (-not (Test-Path -LiteralPath (Join-Path $Src 'hooks\register.ts'))) { throw "The mod is missing from this kit: $Src" }

$settings = if (Test-Path -LiteralPath $SettingsPath) { Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$cur = if ($settings.PSObject.Properties['env'] -and $settings.env.PSObject.Properties[$Key]) { [string]$settings.env.$Key } else { '' }
$isOurs = $cur -and $cur.TrimEnd('/', '\') -ieq $DstFwd

function Get-Levels {
    $f = Join-Path $Dst 'hooks\register.ts'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $m = [regex]::Match((Get-Content -LiteralPath $f -Raw -Encoding UTF8), 'const WARN = (\d+), PREPARE = (\d+), HANDOFF = (\d+)')
    if ($m.Success) { return "$($m.Groups[1].Value)/$($m.Groups[2].Value)/$($m.Groups[3].Value)%" } else { return '?' }
}
function Save-Settings {
    if ($DryRun) {
        Write-Host "DRY RUN: $SettingsPath would get this env section (other settings unchanged):" -ForegroundColor Yellow
        if ($settings.PSObject.Properties['env']) { $settings.env | ConvertTo-Json -Depth 5 } else { '(no env)' }
        return
    }
    if (Test-Path -LiteralPath $SettingsPath) { Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    Write-Utf8 $SettingsPath ($settings | ConvertTo-Json -Depth 20)
    Write-Host "Saved $SettingsPath."
}

if (-not $On -and -not $Off) {
    if ($isOurs -and (Test-Path -LiteralPath $Dst)) { Write-Host "Usage warnings: on (levels $(Get-Levels)), mod at $Dst" }
    elseif ($isOurs) { Write-Host "Usage warnings: switched on in settings.json but the mod is missing at $Dst. Run -On again." -ForegroundColor Yellow }
    elseif ($cur) { Write-Host "Usage warnings: off ($Key is set to another folder: $cur)" }
    else { Write-Host 'Usage warnings: off' }
    return
}

if ($On) {
    if (-not ($Warn -lt $Prepare -and $Prepare -lt $Handoff)) { throw "Levels must rise: Warn ($Warn) < Prepare ($Prepare) < Handoff ($Handoff)." }
    if ($cur -and -not $isOurs) {
        throw "$Key in $SettingsPath already points to another folder ($cur). Nothing changed. Remove that line or add the mod folder ($DstFwd) by hand."
    }
    if ($DryRun) { Write-Host "DRY RUN: would copy the mod to $Dst with levels $Warn/$Prepare/$Handoff%." -ForegroundColor Yellow }
    else {
        if (Test-Path -LiteralPath $Dst) { Remove-Item -LiteralPath $Dst -Recurse -Force }
        New-Item -ItemType Directory -Path $P.State -Force | Out-Null
        Copy-Item -LiteralPath $Src -Destination $Dst -Recurse
        $f = Join-Path $Dst 'hooks\register.ts'
        $ts = Get-Content -LiteralPath $f -Raw -Encoding UTF8
        if ($ts -notmatch $LevelsRx) { throw "Could not find the levels line in $f." }
        Write-Utf8 $f ([regex]::Replace($ts, $LevelsRx, "const WARN = $Warn, PREPARE = $Prepare, HANDOFF = $Handoff"))
        Write-Host "Mod copied to $Dst (levels $Warn/$Prepare/$Handoff%)."
    }
    if (-not $settings.PSObject.Properties['env']) { $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
    if ($settings.env.PSObject.Properties[$Key]) { $settings.env.$Key = $DstFwd } else { $settings.env | Add-Member -NotePropertyName $Key -NotePropertyValue $DstFwd }
    Save-Settings
    Write-Host 'Usage warnings are on. They take effect in new sessions.' -ForegroundColor Green
    return
}

# -Off
if ($cur -and -not $isOurs) { Write-Host "$Key points to another folder ($cur); left as is." -ForegroundColor Yellow }
elseif ($isOurs) {
    $settings.env.PSObject.Properties.Remove($Key)
    if (-not @($settings.env.PSObject.Properties).Count) { $settings.PSObject.Properties.Remove('env') }
    Save-Settings
}
if (Test-Path -LiteralPath $Dst) {
    if ($DryRun) { Write-Host "DRY RUN: would remove $Dst." -ForegroundColor Yellow }
    else { Remove-Item -LiteralPath $Dst -Recurse -Force; Write-Host "Removed $Dst." }
}
Write-Host 'Usage warnings are off. New sessions start without them.' -ForegroundColor Green
