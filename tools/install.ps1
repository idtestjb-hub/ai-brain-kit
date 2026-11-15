<#
.SYNOPSIS
  Sets up the shared AI brain on this Windows machine and syncs it over Tailscale with Syncthing.

.DESCRIPTION
  First machine (creates a new, empty brain):
    install.ps1 -WorkFolder "D:\Work"
  Another machine (joins an existing brain; the brain's content arrives by sync):
    install.ps1 -WorkFolder "D:\Work" -PeerId <Device ID> -PeerIp <Tailscale IP> -PeerName <name>

  WorkFolder is the folder you usually open the assistant in. Its automatic memory becomes the shared memory.
  Safe to run again. It never syncs sign-ins, settings.json or conversation history.
  Advanced/test options: -HomeRoot, -GuiPort, -ListenPort, -PeerPort, -NoTask, -NoWinget, -WaitMinutes.
#>
param(
    [Parameter(Mandatory)][string]$WorkFolder,
    [string]$PeerId,
    [string]$PeerIp,
    [string]$PeerName = 'peer',
    [int]$PeerPort = 22000,
    [string]$HomeRoot,
    [int]$GuiPort = 8384,
    [int]$ListenPort = 22000,
    [int]$WaitMinutes = 30,
    [switch]$NoTask,
    [switch]$NoWinget
)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P   = Get-BrainPaths -HomeRoot $HomeRoot
$Ed  = $P.Edition
$Kit = Split-Path $PSScriptRoot -Parent           # kit root: tools\ and templates\
$Join = [bool]$PeerId
function Step($m) { Write-Host "`n== $m" -ForegroundColor Cyan }

Step 'Check prerequisites'
if (-not (Test-Path -LiteralPath $WorkFolder -PathType Container)) {
    throw "WorkFolder does not exist: $WorkFolder`nUse the folder you already open your AI assistant in. If this path is right and the folder is just new, create it first:  mkdir `"$WorkFolder`"  then run this again."
}
$ts = Get-TailscaleIp
if ($Join) {
    if ($PeerId -notmatch '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$') { throw 'PeerId is not a Syncthing Device ID.' }
    if ($PeerIp -notmatch '^100\.\d+\.\d+\.\d+$') { throw 'PeerIp must be the other machine''s Tailscale IPv4 address (100.x.y.z).' }
}
$exe = Find-Syncthing
if (-not $exe) {
    if ($NoWinget) { throw 'Syncthing is not installed.' }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget (App Installer) is missing. Install it from the Microsoft Store, then run this again.' }
    # --source winget: skip the Microsoft Store source, which fails where the Store is absent (e.g. Windows Sandbox).
    winget install -e --id Syncthing.Syncthing --source winget --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
    $exe = Find-Syncthing
    if (-not $exe) { throw 'Syncthing install did not produce syncthing.exe.' }
}
$MemoryDir = Get-MemoryDirFor -ConfigDir $P.Config -WorkFolder $WorkFolder
Write-Host "Mode: $(if ($Join) {'join an existing brain'} else {'first machine'})"
Write-Host "Vault: $($P.Vault)"
Write-Host "Memory for ${WorkFolder}: $MemoryDir"

# ---------------------------------------------------------------------------
$marker = Join-Path $P.State 'installed.txt'
if ($Join -and -not (Test-Path -LiteralPath $marker)) {
    Step 'Prepare this machine to receive the brain'
    if ((Test-Path -LiteralPath $P.Vault) -and @(Get-ChildItem -LiteralPath $P.Vault -Force).Count -gt 0) {
        throw "Vault folder is not empty: $($P.Vault). Move it away first; joining needs an empty vault."
    }
    # Move this machine's own copies aside so the first sync does not create conflict copies.
    $bk = Join-Path $P.Backups ("before-join-" + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    $moved = 0
    foreach ($n in 'CLAUDE.md', 'rules', 'skills', 'agents', 'commands', 'handoffs', 'hooks') {
        $src = Join-Path $P.Config $n
        if (Test-Path -LiteralPath $src) {
            New-Item -ItemType Directory -Path $bk -Force | Out-Null
            Move-Item -LiteralPath $src -Destination (Join-Path $bk $n); $moved++
        }
    }
    if ((Test-Path -LiteralPath $MemoryDir) -and @(Get-ChildItem -LiteralPath $MemoryDir -Force).Count -gt 0) {
        New-Item -ItemType Directory -Path $bk -Force | Out-Null
        Move-Item -LiteralPath $MemoryDir -Destination (Join-Path $bk 'memory'); $moved++
    }
    if ($moved) { Write-Host "Moved $moved existing item(s) to $bk. Merge anything you need back in after the first sync." -ForegroundColor Yellow }
}

Step 'Create folders'
foreach ($d in $P.Config, $P.Vault, $MemoryDir, $P.StHome, $P.Logs) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

if (-not $Join) {
    Step 'Lay down empty templates (existing files are kept)'
    $t = Join-Path $Kit 'templates'
    $map = @(
        @{ From = 'vault';  To = $P.Vault },
        @{ From = 'config'; To = $P.Config },
        @{ From = 'memory'; To = $MemoryDir }
    )
    foreach ($m in $map) {
        $root = Join-Path $t $m.From
        Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\')
            if (Copy-IfMissing $_.FullName (Join-Path $m.To $rel)) { Write-Host "  new    $rel" }
        }
    }
    # The kit's tools live in the vault so every machine gets the same version by sync.
    $toolsDst = Join-Path $P.Vault '_tools'
    New-Item -ItemType Directory -Path $toolsDst -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $toolsDst -Recurse -Force
    $tplDst = Join-Path $P.Vault '_tools\templates'
    if (-not (Test-Path -LiteralPath $tplDst)) { Copy-Item -LiteralPath $t -Destination $tplDst -Recurse }
    Write-Host "  tools  -> $toolsDst"
}

Step 'Write sync filters'
Write-Utf8 (Join-Path $P.Config '.stignore') (Get-ConfigIgnore $Ed)
Write-Utf8 (Join-Path $P.Vault '.stignore') (Get-VaultIgnore $Ed)

Step 'Start a dedicated Syncthing instance'
$env:STNODEFAULTFOLDER = '1'
if (-not (Test-Path -LiteralPath (Join-Path $P.StHome 'config.xml'))) { & $exe generate "--home=$($P.StHome)" | Out-Null }
$serveArgs = @('serve', '--no-browser', '--no-console', "--home=`"$($P.StHome)`"", "--gui-address=127.0.0.1:$GuiPort")
if (-not (Test-StGui -GuiPort $GuiPort)) {
    Start-Process -FilePath $exe -ArgumentList $serveArgs -WindowStyle Hidden -WorkingDirectory $P.StHome
    for ($i = 0; $i -lt 30 -and -not (Test-StGui -GuiPort $GuiPort); $i++) { Start-Sleep 1 }
    if (-not (Test-StGui -GuiPort $GuiPort)) { throw "Syncthing did not start on port $GuiPort. See $($P.StHome)." }
}
Connect-SyncthingApi -StHome $P.StHome -GuiPort $GuiPort
try { $myId = (Invoke-St GET '/rest/system/status').myID }
catch { throw "Another Syncthing instance already uses port $GuiPort. Stop it or pass -GuiPort." }

Step 'Allow traffic over Tailscale only'
Invoke-St PATCH '/rest/config/options' @{
    listenAddresses = @("tcp://${ts}:$ListenPort")
    globalAnnounceEnabled = $false; localAnnounceEnabled = $false
    relaysEnabled = $false; natEnabled = $false; urAccepted = -1
    crashReportingEnabled = $false; autoUpgradeIntervalH = 0; startBrowser = $false
} | Out-Null
Invoke-St PATCH '/rest/config/gui' @{ address = "127.0.0.1:$GuiPort" } | Out-Null

if ($Join) {
    $known = @(Invoke-St GET '/rest/config/devices' | ForEach-Object { $_.deviceID })
    if ($known -notcontains $PeerId) {
        Invoke-St POST '/rest/config/devices' @{ deviceID = $PeerId; name = $PeerName; addresses = @("tcp://${PeerIp}:$PeerPort"); autoAcceptFolders = $false; introducer = $false } | Out-Null
        Write-Host "  added  $PeerName ($PeerIp)"
    }
}

Step 'Share the three folders'
$folders = @(
    @{ id = 'ai-claude'; label = 'AI - config'; path = $P.Config },
    @{ id = 'ai-memory'; label = 'AI - memory'; path = $MemoryDir },
    @{ id = 'ai-brain';  label = 'AI - vault';  path = $P.Vault }
)
$have = @(Invoke-St GET '/rest/config/folders')
foreach ($f in $folders) {
    $cur = $have | Where-Object { $_.id -eq $f.id } | Select-Object -First 1
    if ($cur) {
        $a = [IO.Path]::GetFullPath($cur.path).TrimEnd('\'); $b = [IO.Path]::GetFullPath($f.path).TrimEnd('\')
        if ($a -ine $b) { throw "Folder $($f.id) already points at $a, not $b. Check before running again." }
        if ($Join -and (@($cur.devices | ForEach-Object { $_.deviceID }) -notcontains $PeerId)) {
            $cur.devices = @($cur.devices) + [pscustomobject]@{ deviceID = $PeerId }
            Invoke-St PUT "/rest/config/folders/$($f.id)" $cur | Out-Null
        }
        Write-Host "  ok     $($f.id)"
    } else {
        $devs = @(@{ deviceID = $myId }); if ($Join) { $devs += @{ deviceID = $PeerId } }
        Invoke-St POST '/rest/config/folders' @{
            id = $f.id; label = $f.label; path = $f.path; type = 'sendreceive'; devices = $devs
            # The file watcher can miss new files (seen on Windows); a 5-minute rescan bounds the delay.
            fsWatcherEnabled = $true; rescanIntervalS = 300
            versioning = @{ type = 'trashcan'; params = @{ cleanoutDays = '30' } }
        } | Out-Null
        Write-Host "  new    $($f.id) -> $($f.path)"
    }
}

Write-Utf8 $P.BrainJson ((@{
    workFolder = $WorkFolder; memoryDir = $MemoryDir; guiPort = $GuiPort; listenPort = $ListenPort
    edition = $Ed.id; kitVersion = $Ed.version
} | ConvertTo-Json))
"installed $(Get-Date -Format s)" | Set-Content -LiteralPath $marker -Encoding UTF8

if (-not $NoTask) {
    Step 'Start Syncthing at sign-in'
    $argLine = ($serveArgs -join ' ')
    $act = New-ScheduledTaskAction -Execute $exe -Argument $argLine
    $old = Get-ScheduledTask -TaskName $Ed.taskName -ErrorAction SilentlyContinue
    if ($old) { Set-ScheduledTask -TaskName $Ed.taskName -Action $act | Out-Null; Write-Host "  updated task $($Ed.taskName)" }
    else {
        $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $Ed.taskName -Action $act -Trigger $trg -Settings $set -Description "$($Ed.vaultName): sync over Tailscale" | Out-Null
        Write-Host "  created task $($Ed.taskName)"
    }
}

$connect = Join-Path $PSScriptRoot 'connect-clients.ps1'
if (-not $Join) {
    Step 'Connect the vault and installed AI clients'
    & $connect -HomeRoot $HomeRoot
} elseif ($WaitMinutes -gt 0) {
    Step "Wait up to $WaitMinutes minutes for the first sync"
    Write-Host 'On the other machine, run add-peer.ps1 with the Device ID and IP printed below.' -ForegroundColor Yellow
    Write-Host "  Device ID:    $myId"
    Write-Host "  Tailscale IP: $ts   (port $ListenPort)"
    $need = @((Join-Path $P.Vault 'AGENTS.md'), (Join-Path $P.Config 'CLAUDE.md'), (Join-Path $MemoryDir 'MEMORY.md'))
    $deadline = (Get-Date).AddMinutes($WaitMinutes); $ready = $false
    while ((Get-Date) -lt $deadline) {
        $filesOk = @($need | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0
        $idle = $true
        foreach ($id in 'ai-claude', 'ai-memory', 'ai-brain') {
            try { $s = Invoke-St GET "/rest/db/status?folder=$id"; if ($s.state -ne 'idle' -or $s.needFiles -gt 0) { $idle = $false } } catch { $idle = $false }
        }
        if ($filesOk -and $idle) { $ready = $true; break }
        Start-Sleep 10
    }
    if ($ready) { Step 'Connect the vault and installed AI clients'; & $connect -HomeRoot $HomeRoot }
    else { Write-Host 'First sync not finished yet. When the other machine has added this one, run this script again.' -ForegroundColor Yellow }
}

Write-Host ''
Write-Host "Device ID of this machine : $myId"
Write-Host "Tailscale IP              : $ts (port $ListenPort)"
Write-Host 'To add another machine: run install.ps1 there with -PeerId/-PeerIp of this machine,'
Write-Host 'then run add-peer.ps1 here with the new machine''s ID and IP.'
