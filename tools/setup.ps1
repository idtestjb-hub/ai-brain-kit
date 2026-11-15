<#
.SYNOPSIS
  The menu behind Setup.cmd. Walks a new user through Tailscale, the work folder and the first install,
  joining with an invite code, inviting and accepting machines, and checks. Texts: setup-strings.json.
#>
param([string]$HomeRoot)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
$Ed = $P.Edition
$all = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'setup-strings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$S = if ($Ed.language -and $all.($Ed.language)) { $all.($Ed.language) } else { $all.en }

function T([string]$Key, [object[]]$Fmt) {
    $t = [string]$S.$Key
    if (-not $t) { $t = [string]$all.en.$Key }
    if ($Fmt) { $t = $t -f $Fmt }
    return $t
}
function Ask([string]$Key, [object[]]$Fmt) { return ([string](Read-Host (T $Key $Fmt))).Trim() }
function IsYes([string]$Answer) { return $Answer -match '^(y|yes|c|co)$' }
function IsQuit([string]$Answer) { return $Answer -match '^q$' }
function ToolArgs([hashtable]$A) { if ($HomeRoot) { $A.HomeRoot = $HomeRoot }; return $A }

function Invoke-Tool([string]$Name, [hashtable]$A = @{}) {
    $A = ToolArgs $A
    try { & (Join-Path $PSScriptRoot $Name) @A | Out-Host; return $true }
    catch {
        Write-Host ''
        Write-Host (T 'failed') -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function Confirm-Tailscale {
    while ($true) {
        try { $ip = Get-TailscaleIp; Write-Host (T 'tsOk' $ip) -ForegroundColor Green; return $true }
        catch {
            if ($_.Exception.Message -match 'not installed') {
                Write-Host (T 'tsMissing') -ForegroundColor Yellow
                if (IsYes (Ask 'tsInstallAsk')) {
                    if (Get-Command winget -ErrorAction SilentlyContinue) {
                        winget install -e --id Tailscale.Tailscale --source winget --accept-package-agreements --accept-source-agreements | Out-Host
                    } else { Write-Host (T 'noWinget'); Start-Process 'https://tailscale.com/download/windows' }
                } else { Start-Process 'https://tailscale.com/download/windows' }
                Write-Host (T 'tsSignIn')
            } else { Write-Host (T 'tsNotConnected') -ForegroundColor Yellow }
            if (IsQuit (Ask 'pressEnter')) { return $false }
        }
    }
}

function Select-WorkFolder {
    Write-Host ''
    Write-Host (T 'workFolderWhy')
    $path = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = T 'workFolderDialog'
        $d.ShowNewFolderButton = $true
        $d.SelectedPath = [Environment]::GetFolderPath('MyDocuments')
        if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { $path = $d.SelectedPath }
        $owner.Dispose()
    } catch { $path = $null }
    if (-not $path) { $path = Ask 'workFolderType' }
    if (-not $path) { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        if (-not (IsYes (Ask 'workFolderCreate' $path))) { return $null }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $full = (Resolve-Path -LiteralPath $path).Path
    Write-Host (T 'workFolderPicked' $full) -ForegroundColor Green
    return $full
}

function Read-Invite {
    while ($true) {
        $c = Ask 'pasteCode'
        if (-not $c) { return $null }
        try {
            $i = Read-InviteCode -Code $c -KitName $Ed.kitName
            Write-Host (T 'codeOk' $i.PeerIp) -ForegroundColor Green
            return $c
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}

Write-Host ''
Write-Host (T 'title' @($Ed.vaultName, $Ed.version)) -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path -LiteralPath $P.BrainJson)) {
    Write-Host (T 'menuNew'); Write-Host (T 'optNew'); Write-Host (T 'optJoin'); Write-Host (T 'optQuit')
    $choice = Ask 'choose'
    if ($choice -notin '1', '2') { Write-Host (T 'stopped'); return }
    if (-not (Confirm-Tailscale)) { Write-Host (T 'stopped'); return }
    $code = $null
    if ($choice -eq '2') { $code = Read-Invite; if (-not $code) { Write-Host (T 'stopped'); return } }
    $wf = Select-WorkFolder
    if (-not $wf) { Write-Host (T 'stopped'); return }
    $a = @{ WorkFolder = $wf }
    if ($code) { $a.Invite = $code }
    if (-not (Invoke-Tool 'install.ps1' $a)) { return }
    if (-not $code -and (IsYes (Ask 'inviteNow'))) { Invoke-Tool 'invite.ps1' | Out-Null }
    Write-Host ''; Write-Host (T 'bye') -ForegroundColor Green
    return
}

while ($true) {
    Write-Host ''
    Write-Host (T 'menuHave')
    'optInvite', 'optAccept', 'optCheck', 'optConnect', 'optHooks', 'optQuit' | ForEach-Object { Write-Host (T $_) }
    switch (Ask 'choose') {
        '1' { Invoke-Tool 'invite.ps1' | Out-Null }
        '2' { Write-Host (T 'acceptWait'); Invoke-Tool 'accept.ps1' @{ WaitSeconds = 120 } | Out-Null }
        '3' { Invoke-Tool 'check.ps1' | Out-Null }
        '4' { Invoke-Tool 'connect-clients.ps1' | Out-Null }
        '5' { Invoke-Tool 'register-hooks.ps1' @{ InstallPython = $true } | Out-Null }
        default { Write-Host (T 'bye') -ForegroundColor Green; return }
    }
}
