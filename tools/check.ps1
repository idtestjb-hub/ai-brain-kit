<#
.SYNOPSIS
  Read-only health check of the brain on this machine. Changes nothing.
#>
param([string]$HomeRoot)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
$B = Read-BrainJson $P.BrainJson
$fail = 0
function Res($ok, $what, $detail) {
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    if (-not $ok) { $script:fail++ }
    Write-Host ("{0}  {1}  {2}" -f $tag, $what, $detail) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
if (-not $B) { Res $false 'install' "no $($P.BrainJson)"; exit 1 }

foreach ($path in $P.Config, $P.Vault, $P.State) {
    $i = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    $d = if ($i -and $i.LinkType) { "junction -> $(@($i.Target)[0])" } elseif ($i) { 'folder' } else { 'missing' }
    Res ([bool]$i) $path $d
}
Res (Test-Path -LiteralPath (Join-Path $P.Config 'CLAUDE.md')) 'main instructions' (Join-Path $P.Config 'CLAUDE.md')
Res (Test-Path -LiteralPath (Join-Path $B.memoryDir 'MEMORY.md')) 'shared memory index' $B.memoryDir
Res (Test-Path -LiteralPath (Join-Path $P.Vault 'AGENTS.md')) 'vault AGENTS.md' $P.Vault
$conf = @(Get-ChildItem -LiteralPath $P.Config, $P.Vault -Recurse -Force -Filter '*sync-conflict*' -ErrorAction SilentlyContinue)
Res ($conf.Count -eq 0) 'sync conflicts' "$($conf.Count) file(s)$(if ($conf.Count) { ': ' + (($conf | Select-Object -First 3).FullName -join '; ') })"

try {
    Connect-SyncthingApi -StHome $P.StHome -GuiPort ([int]$B.guiPort)
    $devs = @(Invoke-St GET '/rest/config/devices')
    $myId = (Invoke-St GET '/rest/system/status').myID
    $conns = (Invoke-St GET '/rest/system/connections').connections
    foreach ($id in 'ai-claude', 'ai-memory', 'ai-brain') {
        $s = Invoke-St GET "/rest/db/status?folder=$id"
        $errs = @((Invoke-St GET "/rest/folder/errors?folder=$id").errors | Where-Object { $_ }).Count
        Res ($s.state -eq 'idle' -and $errs -eq 0 -and $s.needFiles -eq 0) "sync $id" "state=$($s.state) need=$($s.needFiles) errors=$errs"
    }
    foreach ($d in $devs | Where-Object { $_.deviceID -ne $myId }) {
        $c = $conns.($d.deviceID)
        $pct = @('ai-claude', 'ai-memory', 'ai-brain' | ForEach-Object { [math]::Round((Invoke-St GET "/rest/db/completion?folder=$_&device=$($d.deviceID)").completion, 1) })
        Res ([bool]$c.connected) "peer $($d.name)" "connected=$([bool]$c.connected) completion=$($pct -join '/')%"
    }
} catch { Res $false 'syncthing' $_.Exception.Message }

$settings = Join-Path $P.Config 'settings.json'
if (Test-Path -LiteralPath $settings) {
    $txt = Get-Content -LiteralPath $settings -Raw
    $n = ([regex]::Matches($txt, 'run_shared_hook\.py')).Count
    $man = Join-Path $P.Config 'hooks\hooks.json'
    $want = if (Test-Path -LiteralPath $man) { @((Get-Content -LiteralPath $man -Raw | ConvertFrom-Json).hooks).Count } else { 0 }
    Res ($n -eq $want) 'hooks registered' "$n of $want in manifest (run register-hooks.ps1 if different)"
}
# Optional plan-usage warnings (only in editions that ship usage-guard.ps1).
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'usage-guard.ps1')) {
    $ugDir = Join-Path $P.State 'usage-guard'
    $ugVal = ''
    if (Test-Path -LiteralPath $settings) {
        $sj = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($sj.PSObject.Properties['env'] -and $sj.env.PSObject.Properties['CLAUDE_CODE_PLUGIN_DIRS']) { $ugVal = [string]$sj.env.CLAUDE_CODE_PLUGIN_DIRS }
    }
    if ($ugVal -and $ugVal.TrimEnd('/', '\') -ieq ($ugDir -replace '\\', '/')) {
        Res (Test-Path -LiteralPath (Join-Path $ugDir 'hooks\register.ts')) 'usage warnings' "on, mod at $ugDir (run usage-guard.ps1 -On if missing)"
    } else {
        Write-Host 'INFO  usage warnings  off (optional: usage-guard.ps1 -On)'
    }
}
Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 } else { Write-Host 'All checks passed.' -ForegroundColor Green }
