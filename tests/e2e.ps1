<#
.SYNOPSIS
  End-to-end test with two fake machines (A, B) on this computer. Each has its own profile folder,
  its own Syncthing instance and ports, so the real brain is never touched. Needs Tailscale signed in,
  Syncthing installed and Python 3. Tests a built kit: the source repo's dist\ (run build.ps1 first),
  or any kit folder given with -Kit (the kit ships this file in tests\, so -Kit . works from its root).
    pwsh -File tests\e2e.ps1 [-Edition public] [-WorkRoot C:\ZWork\kit-e2e] [-Keep]
    pwsh -File tests\e2e.ps1 -Kit . -Shell powershell
#>
param(
    [string]$Edition = 'public',
    [string]$Kit,      # a built kit folder (holds tools\ and templates\); its edition.json sets the edition
    [string]$WorkRoot = 'C:\ZWork\kit-e2e',
    [ValidateSet('pwsh', 'powershell')][string]$Shell = 'powershell',   # end users run Windows PowerShell 5.1
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
if ($Kit) {
    $Kit = Join-Path (Resolve-Path -LiteralPath $Kit).Path 'tools'
    $cfg = Get-Content (Join-Path $Kit 'edition.json') -Raw | ConvertFrom-Json
    $Edition = $cfg.id
} else {
    $Root = Split-Path $PSScriptRoot -Parent
    $cfg  = Get-Content (Join-Path $Root "editions\$Edition\edition.json") -Raw | ConvertFrom-Json
    $Kit  = Join-Path $Root "dist\$Edition\$($cfg.kitName)\tools"
}
if (-not (Test-Path $Kit)) { throw "Build first: $Kit missing" }
$T = Join-Path $WorkRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
$A = @{ Name = 'A'; Home = "$T\A"; Gui = 18384; Listen = 22101 }
$B = @{ Name = 'B'; Home = "$T\B"; Gui = 18385; Listen = 22102 }
foreach ($m in $A, $B) { New-Item -ItemType Directory "$($m.Home)\work" -Force | Out-Null }
$env:TEMP = "$WorkRoot\tmp"; $env:TMP = $env:TEMP; New-Item -ItemType Directory $env:TEMP -Force | Out-Null
$ts = (& tailscale ip -4 | Select-Object -First 1).Trim()
$results = [System.Collections.Generic.List[string]]::new()
$fails = 0
$script:lastOut = $null
function Show-LastOutput {
    # On a failure, print what the last kit command said (CI logs show nothing else).
    if ($script:lastOut) { Write-Host '---- output of the last kit command:'; Write-Host $script:lastOut; Write-Host '----'; $script:lastOut = $null }
}
function Ok($cond, $what) {
    $r = if ($cond) { 'PASS' } else { $script:fails++; 'FAIL' }
    $results.Add("$r  $what"); Write-Host "$r  $what" -ForegroundColor $(if ($cond) { 'Green' } else { 'Red' })
    if (-not $cond) { Show-LastOutput }
}
function LinkType($path) { (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue).LinkType }
function Run($script, [hashtable]$a) {
    # Build "-Name value" / "-Switch" arguments: splatting a hashtable to an exe gives "-Name:value",
    # which Windows PowerShell 5.1 -File cannot bind to switches.
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Kit $script))
    foreach ($k in $a.Keys) {
        $v = $a[$k]
        if ($v -is [bool]) { if ($v) { $argv += "-$k" } }
        else { $argv += "-$k"; $argv += (@($v) -join ',') }
    }
    $o = & $Shell @argv 2>&1 | Out-String
    $script:lastOut = "[$script exit $LASTEXITCODE]`n$o"
    $o
}
function Api($m, $route, $method = 'GET', $body = $null) {
    $key = ([xml](Get-Content "$($m.Home)\$($cfg.stateDirName)\syncthing\config.xml" -Raw)).configuration.gui.apikey
    $p = @{ Uri = "http://127.0.0.1:$($m.Gui)$route"; Method = $method; Headers = @{ 'X-API-Key' = $key } }
    if ($body) { $p.Body = ($body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    $r = Invoke-RestMethod @p; $r
}
function WaitFor([scriptblock]$cond, [int]$sec = 120) {
    $d = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $d) { if (& $cond) { return $true }; Start-Sleep 2 }
    return $false
}
$vault = $cfg.vaultName
$realSync = Test-Path "$env:USERPROFILE\Sync"

try {
    # 1. first machine
    $out = Run 'install.ps1' @{ WorkFolder = "$($A.Home)\work"; HomeRoot = $A.Home; GuiPort = $A.Gui; ListenPort = $A.Listen; NoTask = $true; NoWinget = $true }
    Ok (Test-Path "$($A.Home)\$vault\AGENTS.md") 'A: vault created from templates'
    Ok (Test-Path "$($A.Home)\.claude\CLAUDE.md") 'A: CLAUDE.md template laid down'
    Ok (Test-Path "$($A.Home)\$vault\_tools\install.ps1") 'A: tools copied into vault'
    Ok ((LinkType "$($A.Home)\$vault\memory") -eq 'Junction') 'A: vault memory junction'
    $idA = (Api $A '/rest/system/status').myID
    $opt = Api $A '/rest/config/options'
    Ok (-not $opt.relaysEnabled -and -not $opt.globalAnnounceEnabled -and ($opt.listenAddresses -join ',') -eq "tcp://${ts}:$($A.Listen)") 'A: Tailscale-only options'
    Ok (@(Api $A '/rest/config/folders').Count -eq 3) 'A: exactly three folders (no default folder)'

    # 2. A gives an invite code, the second machine joins with it, then A accepts it
    $out = Run 'invite.ps1' @{ HomeRoot = $A.Home; NoQr = $true; PassThru = $true }
    $code = @($out -split "`r?`n" | Where-Object { $_ -match '^AIB1-' } | Select-Object -Last 1)[0]
    Ok ($code -match '^AIB1-[A-Z2-7]{4}(-[A-Z2-7]{1,4}){16}$') 'A: invite.ps1 prints an invite code'
    New-Item -ItemType Directory "$($B.Home)\.claude\rules" -Force | Out-Null
    Set-Content "$($B.Home)\.claude\CLAUDE.md" 'B own old instructions'
    $out = Run 'install.ps1' @{ WorkFolder = "$($B.Home)\work"; HomeRoot = $B.Home; GuiPort = $B.Gui; ListenPort = $B.Listen; Invite = $code; NoTask = $true; NoWinget = $true; WaitMinutes = 0 }
    $bk = Get-ChildItem "$($B.Home)\$($cfg.stateDirName)-backup" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Ok ($bk -and (Test-Path "$($bk.FullName)\CLAUDE.md")) 'B: own CLAUDE.md moved to backup before join'
    Ok (@(Api $B '/rest/config/devices' | Where-Object { $_.deviceID -eq $idA }).Count -eq 1) 'B: invite code decoded to A''s Device ID'
    $idB = (Api $B '/rest/system/status').myID
    $out = Run 'accept.ps1' @{ HomeRoot = $A.Home; Yes = $true; WaitSeconds = 90; PeerPort = $B.Listen }
    Ok (@(Api $A '/rest/config/devices' | Where-Object { $_.deviceID -eq $idB }).Count -eq 1) 'A: accept.ps1 added the waiting machine'
    $out = Run 'add-peer.ps1' @{ PeerId = $idB; PeerIp = $ts; PeerPort = $B.Listen; PeerName = 'B'; HomeRoot = $A.Home }
    Ok ($out -match 'already known' -and $out -match 'ai-brain already shared') 'A: add-peer.ps1 still works and is idempotent'
    $memB = (Get-Content "$($B.Home)\$($cfg.stateDirName)\brain.json" -Raw | ConvertFrom-Json).memoryDir
    Ok (WaitFor { (Test-Path "$($B.Home)\$vault\AGENTS.md") -and (Test-Path "$($B.Home)\.claude\CLAUDE.md") -and (Test-Path "$memB\MEMORY.md") } 180) 'B: first sync delivered AGENTS.md, CLAUDE.md, MEMORY.md'
    Ok ((Get-Content "$($B.Home)\.claude\CLAUDE.md" -Raw) -notmatch 'B own old') 'B: CLAUDE.md is the shared one, no conflict copy'
    $out = Run 'connect-clients.ps1' @{ HomeRoot = $B.Home }
    Ok ((LinkType "$($B.Home)\$vault\memory") -eq 'Junction') 'B: vault junctions after connect-clients'

    # 2b. dry run, GitHub Copilot and Cursor
    New-Item -ItemType Directory "$($B.Home)\.copilot", "$($B.Home)\.cursor", "$($B.Home)\.claude\skills\demo-skill" -Force | Out-Null
    Set-Content "$($B.Home)\.claude\skills\demo-skill\SKILL.md" "---`nname: demo-skill`ndescription: TEST DATA`n---`nTEST DATA"
    $out = Run 'connect-clients.ps1' @{ HomeRoot = $B.Home; DryRun = $true }
    Ok ($out -match 'would\s+write .*copilot-instructions\.md' -and -not (Test-Path "$($B.Home)\.copilot\copilot-instructions.md") -and -not (Test-Path "$($B.Home)\.copilot\skills")) 'B: connect-clients -DryRun lists Copilot changes, writes nothing'
    Ok ($out -match 'note\s+Cursor') 'B: Cursor gets a note (no user-level file to write)'
    $out = Run 'connect-clients.ps1' @{ HomeRoot = $B.Home }
    Ok ((Get-Content "$($B.Home)\.copilot\copilot-instructions.md" -Raw) -match 'generated from the vault') 'B: Copilot instructions written'
    Ok ((LinkType "$($B.Home)\.copilot\skills\demo-skill") -eq 'Junction') 'B: skill linked for Copilot'
    $out = Run 'connect-clients.ps1' @{ HomeRoot = $B.Home }
    Ok ($out -match 'same\s+.*copilot-instructions\.md') 'B: second run leaves the Copilot file unchanged'

    # 3. round trips and exclusions
    Set-Content "$($B.Home)\$vault\knowledge\from-b.md" 'TEST DATA from B'
    Ok (WaitFor { Test-Path "$($A.Home)\$vault\knowledge\from-b.md" } 90) 'B -> A: vault note'
    $memA = (Get-Content "$($A.Home)\$($cfg.stateDirName)\brain.json" -Raw | ConvertFrom-Json).memoryDir
    Set-Content "$memA\note_test.md" 'TEST DATA memory from A'
    Start-Sleep 15; Api $A '/rest/db/scan?folder=ai-memory' 'POST' | Out-Null   # stands in for the 5-minute rescan
    Ok (WaitFor { Test-Path "$memB\note_test.md" } 90) 'A -> B: memory note (different work-folder paths)'
    New-Item -ItemType Directory "$($A.Home)\.claude\hooks\state", "$($A.Home)\.claude\hooks\__pycache__" -Force | Out-Null
    Set-Content "$($A.Home)\.claude\hooks\state\s.json" '{}'; Set-Content "$($A.Home)\.claude\hooks\__pycache__\x.pyc" 'x'
    Set-Content "$($A.Home)\.claude\settings.json" '{"a":1}'
    Set-Content "$($A.Home)\.claude\hooks\py_syntax_check.py" @'
import ast, json, sys
p = json.load(sys.stdin).get("tool_input", {}).get("file_path", "")
try:
    ast.parse(open(p, encoding="utf-8").read())
except SyntaxError as e:
    print(f"Python syntax error in {p}", file=sys.stderr); sys.exit(2)
'@
    Set-Content "$($A.Home)\.claude\hooks\hooks.json" '{"hooks":[{"name":"py_syntax_check","event":"PostToolUse","matcher":"Write|Edit","timeout":15}]}'
    # The watcher can miss new files; the kit's 5-minute rescan covers that. Trigger the rescan now.
    Ok (@(Api $A '/rest/config/folders' | Where-Object { $_.rescanIntervalS -eq 300 }).Count -eq 3) 'A: 5-minute rescan on all folders'
    Api $A '/rest/db/scan?folder=ai-claude' 'POST' | Out-Null
    Ok (WaitFor { Test-Path "$($B.Home)\.claude\hooks\py_syntax_check.py" } 90) 'A -> B: hook file'
    Start-Sleep 5
    Ok (-not (Test-Path "$($B.Home)\.claude\hooks\state\s.json") -and -not (Test-Path "$($B.Home)\.claude\hooks\__pycache__")) 'hook temp files do not sync'
    Ok (-not (Test-Path "$($B.Home)\.claude\settings.json")) 'settings.json does not sync'

    # 4. hooks on B
    $out = Run 'register-hooks.ps1' @{ HomeRoot = $B.Home; PersonalMemory = $true; DryRun = $true }
    Ok ($out -match 'DRY RUN' -and $out -match 'run_shared_hook' -and -not (Test-Path "$($B.Home)\.claude\settings.json")) 'B: register-hooks -DryRun shows hooks, writes nothing'
    $out = Run 'register-hooks.ps1' @{ HomeRoot = $B.Home; PersonalMemory = $true }
    $s = Get-Content "$($B.Home)\.claude\settings.json" -Raw | ConvertFrom-Json
    Ok ($s.hooks.PostToolUse.Count -eq 1 -and $s.hooks.SessionStart.Count -eq 1) 'B: settings.json has shared hook + personal memory'
    $out = Run 'register-hooks.ps1' @{ HomeRoot = $B.Home; PersonalMemory = $true }
    $s = Get-Content "$($B.Home)\.claude\settings.json" -Raw | ConvertFrom-Json
    Ok ($s.hooks.PostToolUse.Count -eq 1 -and $s.hooks.SessionStart.Count -eq 1) 'B: register-hooks run twice adds no duplicates'
    $cmd = $s.hooks.PostToolUse[0].hooks[0].command
    Set-Content "$T\bad.py" 'def x(:'
    $payload = (@{ tool_input = @{ file_path = "$T\bad.py" } } | ConvertTo-Json -Compress)
    $null = $payload | cmd /c $cmd 2>&1; $code = $LASTEXITCODE
    Ok ($code -eq 2) "B: registered hook runs and blocks bad.py (exit $code)"
    Set-Content "$($B.Home)\.claude\personal-memory\MEMORY.md" '- [Home server](x.md) TEST DATA'
    $pm = '{}' | cmd /c $s.hooks.SessionStart[0].hooks[0].command
    Ok ($pm -match 'Home server') 'B: personal memory hook prints the local index'
    Ok (WaitFor { -not (Test-Path "$($A.Home)\.claude\personal-memory") } 5) 'personal memory stays on B'

    # 4b. handoff format in the templates (both editions)
    $agentsA = Get-Content "$($A.Home)\$vault\AGENTS.md" -Raw -Encoding UTF8
    $claudeA = Get-Content "$($A.Home)\.claude\CLAUDE.md" -Raw -Encoding UTF8
    if ($cfg.language -eq 'vi') { $fromRx = 'B\u00e0n giao t\u1eeb: <m\u00e1y>'; $nextRx = '\u0110\u1ec1 xu\u1ea5t l\u00e0m ti\u1ebfp: <tr\u1ee3 l\u00fd>'; $pasteRx = 'Ti\u1ebfp n\u1ed1i phi\u00ean \[D\u1ef1 \u00e1n\] \(t\u1eeb ' }
    else { $fromRx = 'Handed off from: <machine>'; $nextRx = 'Suggested next: <assistant>'; $pasteRx = 'Continue \[Project\] \(from ' }
    Ok ($agentsA -match $fromRx -and $agentsA -match $nextRx -and $agentsA -match $pasteRx) 'templates: AGENTS.md has the handoff source, suggested-next and paste lines'
    Ok ($claudeA -match $fromRx -and $claudeA -match $nextRx -and $claudeA -match $pasteRx) 'templates: CLAUDE.md has the handoff source, suggested-next and paste lines'

    # 4c. optional plan-usage warnings (public edition only)
    $ugTool = Join-Path $Kit 'usage-guard.ps1'
    $ugDir = "$($B.Home)\$($cfg.stateDirName)\usage-guard"
    $sPath = "$($B.Home)\.claude\settings.json"
    $ugKey = 'CLAUDE_CODE_PLUGIN_DIRS'
    if ($Edition -eq 'public') {
        Ok ((Test-Path $ugTool) -and (Test-Path "$Kit\usage-guard\hooks\register.ts") -and (Test-Path "$Kit\usage-guard\.claude-plugin\plugin.json")) 'public: usage-guard tool and mod in the kit'
        $before = Get-Content $sPath -Raw
        $out = Run 'usage-guard.ps1' @{ HomeRoot = $B.Home; On = $true; DryRun = $true }
        Ok ($out -match 'DRY RUN' -and -not (Test-Path $ugDir) -and (Get-Content $sPath -Raw) -eq $before) 'B: usage-guard -On -DryRun changes nothing'
        $out = Run 'usage-guard.ps1' @{ HomeRoot = $B.Home; On = $true; Warn = 90; Prepare = 80 }
        Ok ($out -match 'Levels must rise' -and -not (Test-Path $ugDir)) 'B: usage-guard refuses levels that do not rise'
        $nBak = @(Get-ChildItem "$sPath.bak-*").Count
        $out = Run 'usage-guard.ps1' @{ HomeRoot = $B.Home; On = $true; Warn = 70; Prepare = 85; Handoff = 92 }
        $s = Get-Content $sPath -Raw | ConvertFrom-Json
        $want = ($ugDir -replace '\\', '/')
        Ok ($s.env.$ugKey -eq $want) 'B: usage-guard -On writes the env line'
        Ok ($s.hooks.PostToolUse.Count -eq 1 -and $s.hooks.SessionStart.Count -eq 1) 'B: usage-guard -On keeps the hooks'
        Ok (@(Get-ChildItem "$sPath.bak-*").Count -gt $nBak) 'B: usage-guard backs up settings.json'
        $reg = [IO.File]::ReadAllText("$ugDir\hooks\register.ts", [Text.Encoding]::UTF8)
        Ok ($reg -match 'const WARN = 70, PREPARE = 85, HANDOFF = 92' -and $reg.Contains([string][char]0x00B7)) 'B: mod copied with the chosen levels, UTF-8 intact'
        Ok (-not (Test-Path "$($B.Home)\.claude\hooks\usage-guard")) 'B: mod stays out of the synced config folder'
        $out = Run 'usage-guard.ps1' @{ HomeRoot = $B.Home; On = $true }
        $s = Get-Content $sPath -Raw | ConvertFrom-Json
        Ok (@($s.env.PSObject.Properties).Count -eq 1 -and $s.env.$ugKey -eq $want) 'B: usage-guard -On twice keeps one env line'
        $out = Run 'usage-guard.ps1' @{ HomeRoot = $B.Home }
        Ok ($out -match 'on \(levels 80/90/95%\)') 'B: usage-guard status shows on with levels'
        $out = Run 'check.ps1' @{ HomeRoot = $B.Home }
        Ok ($out -match 'PASS\s+usage warnings' -and $out -match 'All checks passed') 'B: check.ps1 reports usage warnings on'
        # someone else's plugin folder: refuse, leave it
        $s.env.$ugKey = 'X:/other-plugins'; Set-Content $sPath ($s | ConvertTo-Json -Depth 20)
        $out = Run 'usage-guard.ps1' @{ HomeRoot = $B.Home; On = $true }
        Ok ($out -match 'already points to another folder' -and (Get-Content $sPath -Raw | ConvertFrom-Json).env.$ugKey -eq 'X:/other-plugins') 'B: usage-guard -On leaves another plugin folder alone'
        $s.env.$ugKey = $want; Set-Content $sPath ($s | ConvertTo-Json -Depth 20)
        $out = Run 'usage-guard.ps1' @{ HomeRoot = $B.Home; Off = $true }
        $s = Get-Content $sPath -Raw | ConvertFrom-Json
        Ok (-not $s.PSObject.Properties['env'] -and -not (Test-Path $ugDir) -and $s.hooks.PostToolUse.Count -eq 1) 'B: usage-guard -Off removes the env line and the mod, keeps hooks'
        $out = Run 'check.ps1' @{ HomeRoot = $B.Home }
        Ok ($out -match 'INFO\s+usage warnings\s+off' -and $out -match 'All checks passed') 'B: check.ps1 reports usage warnings off'
    } else {
        Ok (-not (Test-Path $ugTool) -and -not (Test-Path "$Kit\usage-guard")) "${Edition}: no usage-guard in this edition"
        $out = Run 'check.ps1' @{ HomeRoot = $B.Home }
        Ok ($out -notmatch 'usage warnings') "${Edition}: check.ps1 does not mention usage warnings"
    }

    # 5. check
    $out = Run 'check.ps1' @{ HomeRoot = $A.Home }
    Ok ($out -match 'FAIL\s+hooks registered\s+0 of 1') 'A: check.ps1 flags hooks not yet registered on A'
    $out = Run 'register-hooks.ps1' @{ HomeRoot = $A.Home }
    $out = Run 'check.ps1' @{ HomeRoot = $A.Home }; Ok ($out -match 'All checks passed') 'A: check.ps1 passes after register-hooks'
    if ($out -notmatch 'All checks passed') { Write-Host $out }
    $out = Run 'check.ps1' @{ HomeRoot = $B.Home }; Ok ($out -match 'All checks passed') "B: check.ps1 passes"
    if ($out -notmatch 'All checks passed') { Write-Host $out }

    # 6. move B's data to another root, then sync again
    $out = Run 'move-data.ps1' @{ HomeRoot = $B.Home; DataRoot = "$T\B-data"; AppNames = @('no-such-app') }
    Ok ($out -match 'Done\. Old copies') 'B: move-data finished'
    if ($out -notmatch 'Done\. Old copies') { Write-Host $out }
    Ok ((LinkType "$($B.Home)\.claude") -eq 'Junction' -and (LinkType "$($B.Home)\$vault") -eq 'Junction') 'B: move-data left junctions'
    Ok (Test-Path "$T\B-data\.claude\CLAUDE.md") 'B: data at new root'
    Set-Content "$($A.Home)\$vault\knowledge\after-move.md" 'TEST DATA after move'
    Ok (WaitFor { Test-Path "$T\B-data\$vault\knowledge\after-move.md" } 90) 'A -> B after move: still syncing'
    $out = Run 'check.ps1' @{ HomeRoot = $B.Home }; Ok ($out -match 'All checks passed') 'B: check.ps1 passes after move'
    if ($out -notmatch 'All checks passed') { Write-Host $out }
}
catch { $fails++; Write-Host "ERROR: $_" -ForegroundColor Red; Write-Host $_.ScriptStackTrace; Show-LastOutput }
finally {
    foreach ($m in $A, $B) { try { Api $m '/rest/system/shutdown' 'POST' | Out-Null } catch { } }
    Start-Sleep 3
    Ok ((Test-Path "$env:USERPROFILE\Sync") -eq $realSync) 'no default Sync folder created in the real profile'
    if (-not $Keep) {
        # remove junctions first (never recurse through them), then the test tree
        Get-ChildItem $T -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
        Remove-Item $T -Recurse -Force
    }
    Write-Host "`n$($results.Count) checks, $fails failed." -ForegroundColor $(if ($fails) { 'Red' } else { 'Green' })
}
if ($fails) { exit 1 }
