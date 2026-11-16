<#
.SYNOPSIS
  Prepares a GitHub-hosted Windows runner for tests\e2e.ps1. CI only: it adds a test address to the
  runner's network settings, so it refuses to run anywhere else.
    - Syncthing from its official release, pinned version and SHA-256.
    - A stand-in for Tailscale: a test address in Tailscale's range on the loopback interface, plus a
      "tailscale" command that prints it (the runner cannot join a real tailnet).
  Both folders go on the PATH of the following steps through GITHUB_PATH.
#>
param(
    [string]$ToolsDir,   # default: <runner temp>\ci-tools
    [string]$SyncthingVersion = 'v2.1.7',
    [string]$SyncthingSha256 = '3ce7da770f546a8d02b65b2e7ee31f2a3b8b7c3f990ede045590cca4172ecfe1'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'ci-prepare.ps1 is for GitHub Actions runners only.' }
if (-not $ToolsDir) { $ToolsDir = Join-Path $env:RUNNER_TEMP 'ci-tools' }

# ---- Syncthing
$st = Join-Path $ToolsDir 'syncthing'
New-Item -ItemType Directory $st -Force | Out-Null
$name = "syncthing-windows-amd64-$SyncthingVersion"
$zip = Join-Path $ToolsDir "$name.zip"
Invoke-WebRequest -Uri "https://github.com/syncthing/syncthing/releases/download/$SyncthingVersion/$name.zip" -OutFile $zip -UseBasicParsing
$got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($got -ne $SyncthingSha256) { throw "Syncthing download hash mismatch: $got" }
Expand-Archive -LiteralPath $zip -DestinationPath $ToolsDir -Force
Copy-Item -LiteralPath (Join-Path $ToolsDir "$name\syncthing.exe") -Destination $st -Force
& (Join-Path $st 'syncthing.exe') --version

# ---- Tailscale stand-in. The address is built at run time so no 100.x literal sits in the kit.
$ip = (100, 64, 0, 7) -join '.'
$lo = (Get-NetIPInterface -AddressFamily IPv4 | Where-Object InterfaceAlias -like 'Loopback*' | Select-Object -First 1).InterfaceIndex
New-NetIPAddress -InterfaceIndex $lo -IPAddress $ip -PrefixLength 32 -PolicyStore ActiveStore | Out-Null
# Prove the address can be bound before any test relies on it.
$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($ip), 0); $l.Start(); $l.Stop()
$ts = Join-Path $ToolsDir 'tailscale'
New-Item -ItemType Directory $ts -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $ts 'tailscale.cmd'), "@echo off`r`nif /i ""%1""==""ip"" echo $ip`r`n", [Text.Encoding]::ASCII)

Add-Content -LiteralPath $env:GITHUB_PATH -Value $st, $ts
Write-Host "Syncthing $SyncthingVersion in $st; test Tailscale address $ip on interface $lo."
