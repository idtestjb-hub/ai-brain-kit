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

function Add-BrainPeer {
    # Adds a device and shares the three brain folders with it. Call Connect-SyncthingApi first. Safe to repeat.
    param([Parameter(Mandatory)][string]$PeerId, [Parameter(Mandatory)][string]$PeerIp, [int]$PeerPort = 22000, [string]$PeerName = 'peer')
    $known = @(Invoke-St GET '/rest/config/devices' | ForEach-Object { $_.deviceID })
    if ($known -notcontains $PeerId) {
        Invoke-St POST '/rest/config/devices' @{ deviceID = $PeerId; name = $PeerName; addresses = @("tcp://${PeerIp}:$PeerPort"); autoAcceptFolders = $false; introducer = $false } | Out-Null
        Write-Host "Added $PeerName ($PeerIp)"
    } else { Write-Host "$PeerName is already known" }
    foreach ($id in 'ai-claude', 'ai-memory', 'ai-brain') {
        $cur = Invoke-St GET "/rest/config/folders/$id"
        if (@($cur.devices | ForEach-Object { $_.deviceID }) -notcontains $PeerId) {
            $cur.devices = @($cur.devices) + [pscustomobject]@{ deviceID = $PeerId }
            Invoke-St PUT "/rest/config/folders/$id" $cur | Out-Null
            Write-Host "Shared $id with $PeerName"
        } else { Write-Host "$id already shared with $PeerName" }
    }
}

# ---- Invite codes -------------------------------------------------------------
# An invite packs one machine's Syncthing Device ID, Tailscale IP and listen port into one text code.
# Bytes (42): version 1 | 32-byte device ID | IPv4 | port (big-endian) | kit tag | CRC-16/CCITT-FALSE (big-endian)
# Text: 'AIB1-' + base32 (A-Z2-7, no padding) in groups of 4. tools/mac/brain.py uses the same format.

$script:B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

function ConvertTo-Base32 {
    param([byte[]]$Bytes)
    $sb = New-Object Text.StringBuilder
    $buf = 0; $bits = 0
    foreach ($b in $Bytes) {
        $buf = ($buf -shl 8) -bor $b; $bits += 8
        while ($bits -ge 5) {
            [void]$sb.Append($script:B32[($buf -shr ($bits - 5)) -band 31]); $bits -= 5
            $buf = $buf -band ((1 -shl $bits) - 1)
        }
    }
    if ($bits -gt 0) { [void]$sb.Append($script:B32[($buf -shl (5 - $bits)) -band 31]) }
    return $sb.ToString()
}

function ConvertFrom-Base32 {
    param([string]$Text)
    $out = New-Object Collections.Generic.List[byte]
    $buf = 0; $bits = 0
    foreach ($ch in $Text.ToCharArray()) {
        $v = $script:B32.IndexOf($ch)
        if ($v -lt 0) { throw "Invalid character '$ch' in code." }
        $buf = ($buf -shl 5) -bor $v; $bits += 5
        if ($bits -ge 8) {
            $out.Add([byte](($buf -shr ($bits - 8)) -band 0xFF)); $bits -= 8
            $buf = $buf -band ((1 -shl $bits) - 1)
        }
    }
    return ,$out.ToArray()
}

function Get-LuhnBase32 {
    # Syncthing's check character for one 13-character chunk of a Device ID.
    param([string]$Chunk)
    $factor = 1; $sum = 0
    foreach ($ch in $Chunk.ToCharArray()) {
        $add = $factor * $script:B32.IndexOf($ch)
        $factor = 3 - $factor
        $sum += [int][math]::Floor($add / 32) + ($add % 32)
    }
    return $script:B32[(32 - ($sum % 32)) % 32]
}

function ConvertFrom-DeviceId {
    param([Parameter(Mandatory)][string]$DeviceId)
    $s = ($DeviceId.ToUpperInvariant() -replace '[\s-]', '')
    if ($s.Length -ne 56) { throw "Not a Syncthing Device ID: $DeviceId" }
    $data = ''
    for ($i = 0; $i -lt 4; $i++) {
        $chunk = $s.Substring($i * 14, 13)
        if ((Get-LuhnBase32 $chunk) -ne $s[$i * 14 + 13]) { throw "Device ID check failed: $DeviceId" }
        $data += $chunk
    }
    $raw = ConvertFrom-Base32 $data
    return ,([byte[]]$raw[0..31])
}

function ConvertTo-DeviceId {
    param([Parameter(Mandatory)][byte[]]$Raw)
    $b = ConvertTo-Base32 $Raw
    $s = ''
    for ($i = 0; $i -lt 4; $i++) { $c = $b.Substring($i * 13, 13); $s += $c + (Get-LuhnBase32 $c) }
    return (($s -split '(.{7})' | Where-Object { $_ }) -join '-')
}

function Get-DeviceIdFromCert {
    # A Syncthing Device ID is the SHA-256 of the device certificate (DER); no running Syncthing needed.
    param([Parameter(Mandatory)][string]$StHome)
    $pem = Get-Content -LiteralPath (Join-Path $StHome 'cert.pem') -Raw
    $b64 = ($pem -replace '-----[^-]+-----', '') -replace '\s', ''
    $sha = [Security.Cryptography.SHA256]::Create()
    return (ConvertTo-DeviceId $sha.ComputeHash([Convert]::FromBase64String($b64)))
}

function Get-Crc16 {
    param([byte[]]$Bytes)
    $crc = 0xFFFF
    foreach ($b in $Bytes) {
        $crc = $crc -bxor ([int]$b -shl 8)
        for ($i = 0; $i -lt 8; $i++) {
            if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF }
        }
    }
    return $crc
}

function Get-KitTag {
    param([Parameter(Mandatory)][string]$KitName)
    $sha = [Security.Cryptography.SHA256]::Create()
    return $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($KitName))[0]
}

function New-InviteCode {
    param([Parameter(Mandatory)][string]$DeviceId, [Parameter(Mandatory)][string]$Ip, [int]$Port = 22000, [Parameter(Mandatory)][string]$KitName)
    if ($Ip -notmatch '^100\.\d+\.\d+\.\d+$') { throw "Not a Tailscale IPv4 address: $Ip" }
    $p = New-Object Collections.Generic.List[byte]
    $p.Add(1)
    $p.AddRange([byte[]](ConvertFrom-DeviceId $DeviceId))
    foreach ($o in $Ip.Split('.')) { $p.Add([byte][int]$o) }
    $p.Add([byte](($Port -shr 8) -band 0xFF)); $p.Add([byte]($Port -band 0xFF))
    $p.Add([byte](Get-KitTag $KitName))
    $crc = Get-Crc16 $p.ToArray()
    $p.Add([byte](($crc -shr 8) -band 0xFF)); $p.Add([byte]($crc -band 0xFF))
    $b = ConvertTo-Base32 $p.ToArray()
    return 'AIB1-' + (($b -split '(.{4})' | Where-Object { $_ }) -join '-')
}

function Read-InviteCode {
    # Returns PeerId, PeerIp, PeerPort; throws a plain message when the code is mistyped or for another kit.
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$KitName)
    $s = ($Code.ToUpperInvariant() -replace '[\s-]', '')
    if (-not $s.StartsWith('AIB1')) { throw 'This is not an invite code (it should start with AIB1-).' }
    try { $b = ConvertFrom-Base32 $s.Substring(4) } catch { throw 'The invite code has a typo (unexpected character).' }
    if ($b.Length -lt 42 -or $b[0] -ne 1) { throw 'The invite code is incomplete or from a newer kit.' }
    $crc = Get-Crc16 ([byte[]]$b[0..39])
    if ((([int]$b[40] -shl 8) -bor $b[41]) -ne $crc) { throw 'The invite code has a typo (check failed). Copy it again.' }
    if ($b[39] -ne (Get-KitTag $KitName)) { throw 'This invite is for a different kit.' }
    [pscustomobject]@{
        PeerId   = ConvertTo-DeviceId ([byte[]]$b[1..32])
        PeerIp   = ($b[33..36] | ForEach-Object { [string]$_ }) -join '.'
        PeerPort = ([int]$b[37] -shl 8) -bor $b[38]
    }
}
