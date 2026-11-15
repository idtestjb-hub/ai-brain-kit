# Shared helpers for the AI Brain kit. Dot-source this file; it defines functions only.
# Works in Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'Stop'

function Get-Edition {
    # edition.json sits next to the scripts (copied in by build.ps1)
    $p = Join-Path $PSScriptRoot 'edition.json'
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing $p. Use a built kit (dist), not the source folder." }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-BrainPaths {
    # HomeRoot lets a test run use a fake profile folder; normal runs use the real profile.
    param([string]$HomeRoot)
    $ed = Get-Edition
    if (-not $HomeRoot) { $HomeRoot = $env:USERPROFILE }
    $state = Join-Path $HomeRoot $ed.stateDirName
    [pscustomobject]@{
        Edition    = $ed
        Home       = $HomeRoot
        Config     = Join-Path $HomeRoot '.claude'
        Vault      = Join-Path $HomeRoot $ed.vaultName
        State      = $state
        StHome     = Join-Path $state 'syncthing'
        Logs       = Join-Path $state 'logs'
        Backups    = Join-Path $HomeRoot ($ed.stateDirName + '-backup')
        BrainJson  = Join-Path $state 'brain.json'
    }
}

function Get-MemoryDirFor {
    # The assistant keeps automatic memory per working folder, under projects\<encoded path>\memory.
    # Encoding: every character that is not a letter or digit becomes '-'.
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)][string]$WorkFolder)
    $full = [IO.Path]::GetFullPath($WorkFolder).TrimEnd('\')
    $enc = $full -replace '[^A-Za-z0-9]', '-'
    return (Join-Path $ConfigDir "projects\$enc\memory")
}

function Write-Utf8 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path -Force).Attributes = 'Normal' }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Copy-IfMissing {
    # Copies a template file only when the target does not exist. Never overwrites.
    param([string]$Source, [string]$Target)
    if (Test-Path -LiteralPath $Target) { return $false }
    $dir = Split-Path $Target -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Target
    return $true
}

function Set-Junction {
    # Creates a junction; leaves real folders and junctions pointing elsewhere untouched.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { Write-Host "  skip   $Path (target missing: $Target)"; return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.LinkType -eq 'Junction') {
            if ((@($item.Target)[0]).TrimEnd('\') -ieq $Target.TrimEnd('\')) { return }
            Write-Warning "$Path is a junction to $(@($item.Target)[0]); left unchanged."; return
        }
        Write-Warning "$Path is a real folder or file; left unchanged."; return
    }
    $parent = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    Write-Host "  link   $Path -> $Target"
}

function Get-TailscaleIp {
    $exe = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
    if (-not $exe) {
        # A PowerShell window opened before Tailscale was installed has no tailscale on its PATH yet.
        $default = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        if (Test-Path -LiteralPath $default) { $exe = $default }
    }
    if (-not $exe) { throw 'Tailscale is not installed. Install it, sign in, then run this again.' }
    $ip = @(& $exe ip -4 2>$null | Select-Object -First 1)[0]
    if (-not $ip) { throw 'Tailscale is not connected. Sign in, then run this again.' }
    $ip = $ip.Trim()
    if ($ip -notmatch '^100\.\d+\.\d+\.\d+$') { throw "Unexpected Tailscale address: $ip" }
    return $ip
}

function Find-Syncthing {
    $exe = (Get-Command syncthing -ErrorAction SilentlyContinue).Source
    if (-not $exe) {
        $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\syncthing.exe'
        if (Test-Path -LiteralPath $link) { $exe = $link }
    }
    if (-not $exe) {
        $pk = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        $exe = Get-ChildItem -LiteralPath $pk -Directory -Filter 'Syncthing.Syncthing_*' -ErrorAction SilentlyContinue |
            Get-ChildItem -Recurse -Filter syncthing.exe -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    return $exe
}

function Find-Python {
    # Prefer a real install over the Microsoft Store stub in WindowsApps.
    $cands = @()
    $cands += Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python') -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'python.exe' }
    $cands += Get-ChildItem "$env:ProgramFiles\Python3*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'python.exe' }
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py -and $py.Source -notlike '*\WindowsApps\*') { return $py.Source }
    return $null
}

# ---- Syncthing REST ---------------------------------------------------------

function Connect-SyncthingApi {
    param([Parameter(Mandatory)][string]$StHome, [int]$GuiPort = 8384)
    $cfg = Join-Path $StHome 'config.xml'
    if (-not (Test-Path -LiteralPath $cfg)) { throw "No Syncthing config at $cfg. Run install.ps1 first." }
    # config.xml is only read for the API key; it is never edited directly.
    $script:StKey = ([xml](Get-Content -LiteralPath $cfg -Raw)).configuration.gui.apikey
    $script:StGui = "http://127.0.0.1:$GuiPort"
}

function Invoke-St {
    param([string]$Method, [string]$Route, $Body = $null)
    $a = @{ Method = $Method; Uri = "$script:StGui$Route"; Headers = @{ 'X-API-Key' = $script:StKey }; TimeoutSec = 15 }
    if ($null -ne $Body) {
        $a.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20))
        $a.ContentType = 'application/json; charset=utf-8'
    }
    # Invoke-RestMethod emits a JSON array as one object; writing the variable unrolls it,
    # so callers get one item per folder/device and @(...) counts correctly.
    $r = Invoke-RestMethod @a
    $r
}

function Test-StGui {
    param([int]$GuiPort = 8384)
    try { Invoke-RestMethod "http://127.0.0.1:$GuiPort/rest/noauth/health" -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}

function Get-ConfigIgnore {
    param($Edition)
@"
// $($Edition.vaultName): sync knowledge only. Never sync sign-ins, settings or conversation history.
(?d)/hooks/state
(?d)**/__pycache__
!/CLAUDE.md
!/rules
!/skills
!/agents
!/commands
!/handoffs
!/hooks
*
"@
}

function Get-VaultIgnore {
    param($Edition)
@"
// $($Edition.vaultName): these junctions point into the config folder, which syncs on its own.
/config/rules
/config/skills
/config/agents
/config/commands
/config/CLAUDE (read-only copy).md
/memory
/handoffs
/.obsidian/workspace*.json
/.trash
"@
}

function Read-BrainJson {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return $null
}
