<#
.SYNOPSIS
  Pairs this machine with another one for the three brain folders. Run it on BOTH machines,
  each with the other machine's Device ID and Tailscale IP. Safe to run again.
    add-peer.ps1 -PeerId <ID> -PeerIp <100.x.y.z> -PeerName <name>
  Only adds the device and shares the folders: filters, network options and the startup task stay as they are.
#>
param(
    [Parameter(Mandatory)][string]$PeerId,
    [Parameter(Mandatory)][string]$PeerIp,
    [Parameter(Mandatory)][string]$PeerName,
    [int]$PeerPort = 22000,
    [string]$HomeRoot
)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
$B = Read-BrainJson $P.BrainJson
$port = if ($B -and $B.guiPort) { [int]$B.guiPort } else { 8384 }
if ($PeerId -notmatch '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$') { throw 'PeerId is not a Syncthing Device ID.' }
if ($PeerIp -notmatch '^100\.\d+\.\d+\.\d+$') { throw 'PeerIp must be a Tailscale IPv4 address (100.x.y.z).' }
Connect-SyncthingApi -StHome $P.StHome -GuiPort $port
$myId = (Invoke-St GET '/rest/system/status').myID
if ($PeerId -eq $myId) { throw 'PeerId is this machine''s own ID.' }

Add-BrainPeer -PeerId $PeerId -PeerIp $PeerIp -PeerPort $PeerPort -PeerName $PeerName

Write-Host "`nDevice ID of this machine: $myId"
try { Write-Host "Tailscale IP: $(Get-TailscaleIp)" } catch { }
