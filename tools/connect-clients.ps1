<#
.SYNOPSIS
  Connects the vault with the AI tools on this machine. Safe to run again.
  - Junctions in the vault pointing into the config folder (rules, skills, agents, commands, memory, handoffs)
  - A read-only copy of CLAUDE.md in the vault
  - AGENTS.md (master copy in the vault) copied to each installed tool's user-level instructions file
  - Each skill linked into the user-level skill folder of each installed tool
  Run it again after adding a skill or editing AGENTS.md. Never deletes real folders.
    connect-clients.ps1 -DryRun     # show what would change, change nothing
#>
param([string]$HomeRoot, [switch]$DryRun)
. (Join-Path $PSScriptRoot 'brain-common.ps1')
$P  = Get-BrainPaths -HomeRoot $HomeRoot
$Ed = $P.Edition
$B  = Read-BrainJson $P.BrainJson
if (-not $B) { throw "No $($P.BrainJson). Run install.ps1 first." }
$Marker = "<!-- $($Ed.vaultName): generated from the vault's AGENTS.md by _tools/connect-clients.ps1. Edit the original, not this copy. -->"
$H = $P.Home
$AppData = if ($HomeRoot) { Join-Path $HomeRoot 'AppData\Roaming' } else { $env:APPDATA }
if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor Yellow }

# ---- tool table: where each installed tool reads user-level instructions and skills
# Detect = folder that exists once the tool is installed. Head = text required before the content (front matter).
# Sources checked 15/11/2026: cursor.com/docs/context/skills and /rules; code.visualstudio.com custom-instructions
# reference and agent-skills; docs.github.com Copilot CLI custom instructions and skills.
$CopilotHome = if ($env:COPILOT_HOME -and -not $HomeRoot) { $env:COPILOT_HOME } else { Join-Path $H '.copilot' }
$Tools = @(
    @{ Name = 'Codex';              Detect = @(Join-Path $H '.codex');           File = Join-Path $H '.codex\AGENTS.md';           Head = ''; Skills = @(Join-Path $H '.agents\skills') },
    @{ Name = 'Gemini/Antigravity'; Detect = @(Join-Path $H '.gemini');          File = Join-Path $H '.gemini\GEMINI.md';          Head = ''; Skills = @((Join-Path $H '.gemini\config\skills'), (Join-Path $H '.gemini\antigravity\skills')) },
    @{ Name = 'OpenCode';           Detect = @(Join-Path $H '.config\opencode'); File = Join-Path $H '.config\opencode\AGENTS.md'; Head = ''; Skills = @() },
    # GitHub Copilot: the VS Code Copilot agent and Copilot CLI share ~/.copilot (user-level instructions and skills).
    @{ Name = 'GitHub Copilot';     Detect = @($CopilotHome, (Join-Path $AppData 'Code\User')); File = Join-Path $CopilotHome 'copilot-instructions.md'; Head = ''; Skills = @(Join-Path $CopilotHome 'skills') },
    # Cursor: no user-level instructions file (global rules live in Settings > Rules); it reads ~/.claude/skills by itself.
    @{ Name = 'Cursor';             Detect = @((Join-Path $H '.cursor'), (Join-Path $AppData 'Cursor')); File = $null; Head = ''; Skills = @()
       Note = 'global rules are only in Cursor Settings > Rules (paste AGENTS.md there once); skills are read from ~/.claude/skills directly' }
)
function Test-Installed($t) { foreach ($d in $t.Detect) { if (Test-Path -LiteralPath $d) { return $true } }; return $false }

function Act([string]$msg, [scriptblock]$do) {
    if ($DryRun) { Write-Host "  would  $msg" } else { & $do; Write-Host "  $msg" }
}
function Link([string]$Path, [string]$Target) {
    if ($DryRun) {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (-not $i) { Write-Host "  would  link $Path -> $Target" }
        elseif (-not $i.LinkType) { Write-Host "  keep   $Path (real folder, left as is)" }
        return
    }
    Set-Junction $Path $Target
}

if (-not $DryRun) {
    foreach ($d in 'rules', 'skills', 'agents', 'commands', 'handoffs', 'hooks') {
        $dir = Join-Path $P.Config $d; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
}

Write-Host 'Vault links:'
foreach ($d in 'rules', 'skills', 'agents', 'commands') { Link (Join-Path $P.Vault "config\$d") (Join-Path $P.Config $d) }
Link (Join-Path $P.Vault 'memory')   $B.memoryDir
Link (Join-Path $P.Vault 'handoffs') (Join-Path $P.Config 'handoffs')

$src = Join-Path $P.Config 'CLAUDE.md'
if (Test-Path -LiteralPath $src) {
    $copy = Join-Path $P.Vault 'config\CLAUDE (read-only copy).md'
    Act "write  $copy" {
        $head = "> Read-only copy made $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Edit ``~/.claude/CLAUDE.md`` and run ``_tools/connect-clients.ps1`` again.`r`n`r`n"
        Write-Utf8 $copy ($head + [IO.File]::ReadAllText($src))
    }
}

$agentsFile = Join-Path $P.Vault 'AGENTS.md'
$agents = if (Test-Path -LiteralPath $agentsFile) { [IO.File]::ReadAllText($agentsFile) } else { $null }
Write-Host 'Client instructions:'
foreach ($t in $Tools) {
    if (-not (Test-Installed $t)) { Write-Host "  skip   $($t.Name) (not installed)"; continue }
    if (-not $t.File) { Write-Host "  note   $($t.Name): $($t.Note)"; continue }
    if (-not $agents) { Write-Host "  skip   $($t.Name): no AGENTS.md in the vault yet (wait for the first sync)"; continue }
    $f = $t.File
    $new = "$($t.Head)$Marker`r`n`r`n$agents"
    if (Test-Path -LiteralPath $f) {
        $old = [IO.File]::ReadAllText($f)
        if ($old -ceq $new) { Write-Host "  same   $f"; continue }
        if (-not $old.Contains($Marker)) {
            $bak = "$f.before-brain-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Act "backup $f -> $bak (file was not made by this script)" { Copy-Item -LiteralPath $f -Destination $bak }
        }
    }
    Act "write  $f ($($t.Name))" { Write-Utf8 $f $new }
}

$skills = Join-Path $P.Config 'skills'
$skillList = @(Get-ChildItem -LiteralPath $skills -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
Write-Host "Skills ($($skillList.Count) in $skills):"
foreach ($t in $Tools) {
    if (-not (Test-Installed $t)) { continue }
    foreach ($sh in $t.Skills) {
        if (-not (Test-Path -LiteralPath $sh)) { Act "create $sh" { New-Item -ItemType Directory -Path $sh -Force | Out-Null } }
        Get-ChildItem -LiteralPath $sh -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -eq 'Junction' } | ForEach-Object {
            $tg = @($_.Target)[0]; $full = $_.FullName
            if ($tg -like "$skills\*" -and -not (Test-Path -LiteralPath $tg)) { Act "remove $full (skill deleted)" { [IO.Directory]::Delete($full) } }
        }
        $n = 0
        foreach ($s in $skillList) {
            $link = Join-Path $sh $s.Name
            if (-not (Test-Path -LiteralPath $link)) {
                $n++
                if (-not $DryRun) { New-Item -ItemType Junction -Path $link -Target $s.FullName | Out-Null }
            }
        }
        Write-Host ("  {0} {1} : {2} new ({3})" -f $(if ($DryRun) { 'would ' } else { '' }), $sh, $n, $t.Name)
    }
}
Write-Host $(if ($DryRun) { 'Dry run done. Run again without -DryRun to apply.' } else { 'Done.' })
