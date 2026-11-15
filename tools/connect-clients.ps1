<#
.SYNOPSIS
  Connects the vault with the AI tools on this machine. Safe to run again.
  - Junctions in the vault pointing into the config folder (rules, skills, agents, commands, memory, handoffs)
  - A read-only copy of CLAUDE.md in the vault
  - AGENTS.md (master copy in the vault) copied to Codex, Gemini/Antigravity and OpenCode, when installed
  - Each skill linked into the skill folders of Codex and Antigravity
  Run it again after adding a skill or editing AGENTS.md. Never deletes real folders.
#>
param([string]$HomeRoot)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P  = Get-BrainPaths -HomeRoot $HomeRoot
$Ed = $P.Edition
$B  = Read-BrainJson $P.BrainJson
if (-not $B) { throw "No $($P.BrainJson). Run install.ps1 first." }
$Marker = "<!-- $($Ed.vaultName): generated from the vault's AGENTS.md by _tools/connect-clients.ps1. Edit the original, not this copy. -->"

foreach ($d in 'rules', 'skills', 'agents', 'commands', 'handoffs', 'hooks') {
    $dir = Join-Path $P.Config $d; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Write-Host 'Vault links:'
foreach ($d in 'rules', 'skills', 'agents', 'commands') { Set-Junction (Join-Path $P.Vault "config\$d") (Join-Path $P.Config $d) }
Set-Junction (Join-Path $P.Vault 'memory')   $B.memoryDir
Set-Junction (Join-Path $P.Vault 'handoffs') (Join-Path $P.Config 'handoffs')

$src = Join-Path $P.Config 'CLAUDE.md'
if (Test-Path -LiteralPath $src) {
    $head = "> Read-only copy made $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Edit ``~/.claude/CLAUDE.md`` and run ``_tools/connect-clients.ps1`` again.`r`n`r`n"
    Write-Utf8 (Join-Path $P.Vault 'config\CLAUDE (read-only copy).md') ($head + [IO.File]::ReadAllText($src))
}

$agentsFile = Join-Path $P.Vault 'AGENTS.md'
Write-Host 'Client instructions:'
if (Test-Path -LiteralPath $agentsFile) {
    $agents = [IO.File]::ReadAllText($agentsFile)
    $targets = @(
        @{ Dir = Join-Path $P.Home '.codex';           File = 'AGENTS.md'; Name = 'Codex' },
        @{ Dir = Join-Path $P.Home '.gemini';          File = 'GEMINI.md'; Name = 'Gemini/Antigravity' },
        @{ Dir = Join-Path $P.Home '.config\opencode'; File = 'AGENTS.md'; Name = 'OpenCode' }
    )
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Dir)) { Write-Host "  skip   $($t.Name) (not installed)"; continue }
        $f = Join-Path $t.Dir $t.File
        if ((Test-Path -LiteralPath $f) -and ((Get-Content -LiteralPath $f -TotalCount 1) -ne $Marker)) {
            $bak = "$f.before-brain-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -LiteralPath $f -Destination $bak
            Write-Host "  backup $f -> $bak (file was not made by this script)"
        }
        Write-Utf8 $f "$Marker`r`n`r`n$agents"
        Write-Host "  write  $f"
    }
} else { Write-Host '  skip   no AGENTS.md in the vault yet (wait for the first sync, then run again)' }

$homes = @()
if (Test-Path -LiteralPath (Join-Path $P.Home '.codex'))  { $homes += Join-Path $P.Home '.agents\skills' }
if (Test-Path -LiteralPath (Join-Path $P.Home '.gemini')) { $homes += (Join-Path $P.Home '.gemini\config\skills'), (Join-Path $P.Home '.gemini\antigravity\skills') }
$skills = Join-Path $P.Config 'skills'
Write-Host 'Skills:'
foreach ($sh in $homes) {
    if (-not (Test-Path -LiteralPath $sh)) { New-Item -ItemType Directory -Path $sh -Force | Out-Null }
    Get-ChildItem -LiteralPath $sh -Force -Directory | Where-Object { $_.LinkType -eq 'Junction' } | ForEach-Object {
        $tg = @($_.Target)[0]
        if ($tg -like "$skills\*" -and -not (Test-Path -LiteralPath $tg)) { [IO.Directory]::Delete($_.FullName); Write-Host "  remove $($_.FullName) (skill deleted)" }
    }
    $n = 0
    Get-ChildItem -LiteralPath $skills -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object {
        $link = Join-Path $sh $_.Name
        if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target $_.FullName | Out-Null; $n++ }
    }
    Write-Host "  $sh : $n new"
}
Write-Host 'Done.'
