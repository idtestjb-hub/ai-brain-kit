<#
.SYNOPSIS
  Accepts a new machine that joined with this machine's invite code: lists machines waiting to pair,
  asks before adding each one, then shares the three brain folders with it.
    accept.ps1                 ask for each waiting machine
    accept.ps1 -WaitSeconds 120  keep looking for up to 2 minutes if none is waiting yet
  Only machines on your Tailscale network (100.x.y.z) are offered.
  Test options: -Yes (no questions), -PeerPort (the new machine's listen port, default 22000), -HomeRoot.
#>
param([string]$HomeRoot, [int]$WaitSeconds = 0, [int]$PeerPort = 22000, [switch]$Yes)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
$B = Read-BrainJson $P.BrainJson
if (-not $B) { throw 'This machine has no brain yet. Run install.ps1 first.' }
$gui = if ($B.guiPort) { [int]$B.guiPort } else { 8384 }
Connect-SyncthingApi -StHome $P.StHome -GuiPort $gui
if (-not (Test-StGui -GuiPort $gui)) { throw 'Syncthing is not running on this machine. Sign out and in again, or run install.ps1 again.' }

function Get-Waiting {
    $pend = Invoke-St GET '/rest/cluster/pending/devices'
    if (-not $pend) { return @() }
    @($pend.PSObject.Properties | ForEach-Object {
        # The address is where the new machine connected from; only its IP is useful (the port is temporary).
        $ip = if ([string]$_.Value.address -match '(\d+\.\d+\.\d+\.\d+)') { $Matches[1] } else { '' }
        [pscustomobject]@{ Id = $_.Name; Name = [string]$_.Value.name; Ip = $ip }
    } | Where-Object { $_.Ip -match '^100\.\d+\.\d+\.\d+$' })
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$waiting = @(Get-Waiting)
while ($waiting.Count -eq 0 -and (Get-Date) -lt $deadline) {
    Write-Host 'No new machine is waiting yet; looking again in 10 seconds...'
    Start-Sleep 10
    $waiting = @(Get-Waiting)
}
if ($waiting.Count -eq 0) {
    Write-Host 'No new machine is waiting to join.' -ForegroundColor Yellow
    Write-Host 'On the new machine, run Setup > Join with this machine''s invite code (Setup > Invite), then run this again.'
    return
}

$added = 0
foreach ($w in $waiting) {
    $label = if ($w.Name) { $w.Name } else { 'unnamed machine' }
    Write-Host ''
    Write-Host "Waiting to join: $label  ($($w.Ip))"
    Write-Host "  Device ID: $($w.Id)"
    $ok = $Yes
    if (-not $ok) { $ok = (Read-Host 'Add this machine to your brain? Only say yes if you recognise it (y/N)') -match '^(y|yes|c|co)$' }
    if ($ok) {
        $name = if ($w.Name) { $w.Name } else { "machine-$($w.Ip)" }
        Add-BrainPeer -PeerId $w.Id -PeerIp $w.Ip -PeerPort $PeerPort -PeerName $name
        $added++
    } else { Write-Host 'Skipped.' }
}
Write-Host ''
if ($added) { Write-Host "Done: $added machine(s) added. The first sync starts within a minute." -ForegroundColor Green }
