<#
.SYNOPSIS
  Moves the brain's real data (config folder, vault, Syncthing state) to another drive and leaves
  junctions with the same names in the profile, so every app and script keeps working.
  Close the AI apps first (including tray icons). Check without changing anything:
    move-data.ps1 -DataRoot "E:\AI-Context" -Check
  Move:
    move-data.ps1 -DataRoot "E:\AI-Context"
  The new root is locked to this account, SYSTEM and Administrators (like the profile folder).
  The old copies are renamed into a backup folder in the profile; delete it yourself once all is well.
#>
param(
    [Parameter(Mandatory)][string]$DataRoot,
    [switch]$Check,
    [string]$HomeRoot,
    [string[]]$AppNames = @('claude', 'codex', 'antigravity', 'obsidian')
)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
$Ed = $P.Edition
$B = Read-BrainJson $P.BrainJson
if (-not $B) { throw "No $($P.BrainJson). Run install.ps1 first." }
$port = [int]$B.guiPort
$items = @(
    @{ Name = '.claude';          Src = $P.Config },
    @{ Name = $Ed.vaultName;      Src = $P.Vault },
    @{ Name = $Ed.stateDirName;   Src = $P.State }
)
$Bk = Join-Path $P.Home ($Ed.stateDirName + '-move-backup-' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))

# ---- checks
$problems = @()
# Background services of some apps keep running after quitting; they do not touch these folders.
$busy = Get-Process | Where-Object { $n = $_.ProcessName; ($AppNames | Where-Object { $n -like "$_*" }) -and $n -notlike '*sandbox-service*' }
if ($busy) { $problems += "Close these apps first (tray icon > Quit): $((($busy | Group-Object ProcessName).Name) -join ', ')" }
$drive = [IO.Path]::GetPathRoot($DataRoot)
if (-not (Test-Path -LiteralPath $drive)) { $problems += "Drive $drive does not exist." }
foreach ($it in $items) {
    $i = Get-Item -LiteralPath $it.Src -Force -ErrorAction SilentlyContinue
    if (-not $i) { $problems += "Missing $($it.Src)." }
    elseif ($i.LinkType) { $problems += "$($it.Src) is already a junction to $(@($i.Target)[0])." }
    if (Test-Path -LiteralPath (Join-Path $DataRoot $it.Name)) { $problems += "$(Join-Path $DataRoot $it.Name) already exists." }
}
try { Connect-SyncthingApi -StHome $P.StHome -GuiPort $port; Invoke-St GET '/rest/system/ping' | Out-Null }
catch { $problems += "Syncthing does not answer on port $port." }
if ($problems) { $problems | ForEach-Object { Write-Host "NOT READY: $_" -ForegroundColor Yellow }; exit 1 }
if ($Check) { Write-Host 'Ready. Run again without -Check to move.' -ForegroundColor Green; exit 0 }

function Get-FileCount($root) {
    # Counts files without descending into junctions (same in PowerShell 5.1 and 7).
    $n = 0; $stack = [System.Collections.Generic.Stack[string]]::new(); $stack.Push($root)
    while ($stack.Count) {
        $d = $stack.Pop()
        $n += @([IO.Directory]::GetFiles($d)).Count
        foreach ($sub in [IO.Directory]::GetDirectories($d)) {
            if (-not ((Get-Item -LiteralPath $sub -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($sub) }
        }
    }
    return $n
}
function Copy-Tree($src, $dst) {
    robocopy $src $dst /E /XJ /COPY:DAT /DCOPY:DAT /R:2 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $src -> $dst" }
    $a = Get-FileCount $src; $b = Get-FileCount $dst
    if ($a -ne $b) { throw "File count differs after copy: $a vs $b ($src)" }
}
function Copy-InnerJunctions($src, $dst) {
    # robocopy /XJ skips junctions inside the vault; recreate them with the same targets.
    Get-ChildItem -LiteralPath $src -Recurse -Force -Directory -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length).TrimStart('\')
        New-Item -ItemType Junction -Path (Join-Path $dst $rel) -Target @($_.Target)[0] | Out-Null
    }
}

# ---- move
New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $DataRoot /inheritance:r /grant:r "*${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE) { throw "icacls failed ($LASTEXITCODE)" }

$folders = @(Invoke-St GET '/rest/config/folders')
foreach ($f in $folders) { Invoke-St PATCH "/rest/config/folders/$($f.id)" @{ paused = $true } | Out-Null }
Write-Host 'Paused sync. Copying...'
foreach ($it in $items | Where-Object { $_.Src -ne $P.State }) {   # Syncthing state is copied once it is stopped
    $dst = Join-Path $DataRoot $it.Name
    Copy-Tree $it.Src $dst
    Copy-InnerJunctions $it.Src $dst
    Write-Host "  copied $($it.Src) -> $dst"
}
# Point Syncthing folders at the new real paths (prefix swap), then stop Syncthing to move its own state.
foreach ($f in $folders) {
    foreach ($it in $items) {
        if ($f.path.StartsWith($it.Src, [StringComparison]::OrdinalIgnoreCase)) {
            $new = (Join-Path $DataRoot $it.Name) + $f.path.Substring($it.Src.Length)
            Invoke-St PATCH "/rest/config/folders/$($f.id)" @{ path = $new } | Out-Null
            Write-Host "  sync   $($f.id) -> $new"
        }
    }
}
Invoke-St POST '/rest/system/shutdown' | Out-Null
$deadline = (Get-Date).AddSeconds(30)
while ((Test-StGui -GuiPort $port) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
Start-Sleep 2
if (Test-StGui -GuiPort $port) { throw 'Syncthing did not stop within 30 seconds; nothing was renamed. Stop it and run again.' }
Copy-Tree $P.State (Join-Path $DataRoot $Ed.stateDirName)
Write-Host "  copied $($P.State) -> $(Join-Path $DataRoot $Ed.stateDirName)"

New-Item -ItemType Directory -Path $Bk -Force | Out-Null
foreach ($it in $items) {
    Move-Item -LiteralPath $it.Src -Destination (Join-Path $Bk $it.Name)
    New-Item -ItemType Junction -Path $it.Src -Target (Join-Path $DataRoot $it.Name) | Out-Null
    Write-Host "  link   $($it.Src) -> $(Join-Path $DataRoot $it.Name)"
}

# ---- restart
# Use the sign-in task only if it starts this very Syncthing home (a same-named task may belong to another brain).
$task = Get-ScheduledTask -TaskName $Ed.taskName -ErrorAction SilentlyContinue
if ($task -and ($task.Actions[0].Arguments -like "*$($P.StHome)*")) { Start-ScheduledTask -TaskName $Ed.taskName }
else {
    $env:STNODEFAULTFOLDER = '1'
    Start-Process -FilePath (Find-Syncthing) -ArgumentList @('serve', '--no-browser', '--no-console', "--home=`"$($P.StHome)`"", "--gui-address=127.0.0.1:$port") -WindowStyle Hidden
}
$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-StGui -GuiPort $port) -and (Get-Date) -lt $deadline) { Start-Sleep 1 }
if (-not (Test-StGui -GuiPort $port)) { throw 'Syncthing did not come back. Start it from Task Scheduler and check its log.' }
Connect-SyncthingApi -StHome $P.StHome -GuiPort $port
foreach ($f in $folders) { Invoke-St PATCH "/rest/config/folders/$($f.id)" @{ paused = $false } | Out-Null }
Start-Sleep 5
foreach ($f in @(Invoke-St GET '/rest/config/folders')) {
    $s = Invoke-St GET "/rest/db/status?folder=$($f.id)"
    Write-Host ("  {0,-10} {1,-8} files={2} path={3}" -f $f.id, $s.state, $s.localFiles, $f.path)
}
Write-Host "`nDone. Old copies: $Bk"
Write-Host 'Open the apps again. When everything works, delete that backup folder yourself (it contains your sign-in files).' -ForegroundColor Yellow
Write-Host 'Never delete the junctions in the profile: the apps and Syncthing reach the data through them.'
