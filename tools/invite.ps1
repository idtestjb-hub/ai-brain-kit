<#
.SYNOPSIS
  Shows an invite code (and a QR code) for this machine, so another machine can join this brain.
    invite.ps1
  On the new machine:  install.ps1 -WorkFolder "<folder>" -Invite <code>
  Then here:           accept.ps1
#>
param([string]$HomeRoot, [switch]$NoQr, [switch]$PassThru)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P = Get-BrainPaths -HomeRoot $HomeRoot
$B = Read-BrainJson $P.BrainJson
if (-not $B) { throw 'This machine has no brain yet. Run install.ps1 first.' }
$listen = if ($B.listenPort) { [int]$B.listenPort } else { 22000 }
$myId = Get-DeviceIdFromCert -StHome $P.StHome
$ts = Get-TailscaleIp
$code = New-InviteCode -DeviceId $myId -Ip $ts -Port $listen -KitName $P.Edition.kitName

Write-Host ''
Write-Host 'Invite code for this machine:' -ForegroundColor Cyan
Write-Host ''
Write-Host "  $code"
Write-Host ''
$qr = Join-Path $PSScriptRoot 'qr.ps1'
if (-not $NoQr -and (Test-Path -LiteralPath $qr)) {
    . $qr
    Write-Host 'The same code as a QR (scan it with a phone, then send the text to the new machine):'
    Write-QrConsole -Text $code
}
Write-Host 'Next:'
Write-Host '  1. On the new machine, run Setup and choose "Join", then paste this code'
Write-Host '     (or: install.ps1 -WorkFolder "<folder>" -Invite <code>).'
Write-Host '  2. Back here, run Setup and choose "Accept a new machine" (or: accept.ps1).'
# -PassThru also returns the code, so scripts and tests can read it.
if ($PassThru) { Write-Output $code }
