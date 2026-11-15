# Dependency-free QR code encoder (dot-source this file).
# Alphanumeric mode only, error correction level M, versions 1-10.
# Works on Windows PowerShell 5.1 and PowerShell 7. ASCII-only source.
#
#   New-QrMatrix -Text 'AIB1-ABCD'   -> array of bool[] rows (true = dark), no quiet zone
#   Write-QrConsole -Text 'AIB1-ABCD' -> prints it with half-block characters
#
# The matching Python implementation is mac\qr.py (same algorithm, same output).

$script:QrAlnum = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:'

# Level M, versions 1..10: EC codewords per block, then data codewords per block
$script:QrEcLen = @{ 1 = 10; 2 = 16; 3 = 26; 4 = 18; 5 = 24; 6 = 16; 7 = 18; 8 = 22; 9 = 22; 10 = 26 }
$script:QrBlocks = @{
    1  = @(16)
    2  = @(28)
    3  = @(44)
    4  = @(32, 32)
    5  = @(43, 43)
    6  = @(27, 27, 27, 27)
    7  = @(31, 31, 31, 31)
    8  = @(38, 38, 39, 39)
    9  = @(36, 36, 36, 37, 37)
    10 = @(43, 43, 43, 43, 44)
}
$script:QrAlign = @{
    1  = @()
    2  = @(6, 18)
    3  = @(6, 22)
    4  = @(6, 26)
    5  = @(6, 30)
    6  = @(6, 34)
    7  = @(6, 22, 38)
    8  = @(6, 24, 42)
    9  = @(6, 26, 46)
    10 = @(6, 28, 50)
}

# GF(256) log/exp tables, primitive polynomial 0x11D
function Initialize-QrTables {
    if ($script:QrExp) { return }
    $exp = New-Object 'int[]' 512
    $log = New-Object 'int[]' 256
    $x = 1
    for ($i = 0; $i -lt 255; $i++) {
        $exp[$i] = $x
        $log[$x] = $i
        $x = $x -shl 1
        if ($x -band 0x100) { $x = $x -bxor 0x11D }
    }
    for ($i = 255; $i -lt 512; $i++) { $exp[$i] = $exp[$i - 255] }
    $script:QrExp = $exp
    $script:QrLog = $log
}

function Get-QrGfMul([int]$a, [int]$b) {
    if ($a -eq 0 -or $b -eq 0) { return 0 }
    return $script:QrExp[$script:QrLog[$a] + $script:QrLog[$b]]
}

# Reed-Solomon remainder of $data for $n EC codewords
function Get-QrRsRemainder([int[]]$data, [int]$n) {
    $gen = New-Object 'int[]' 1
    $gen[0] = 1
    for ($i = 0; $i -lt $n; $i++) {
        $nxt = New-Object 'int[]' ($gen.Length + 1)
        for ($j = 0; $j -lt $gen.Length; $j++) {
            $nxt[$j] = $nxt[$j] -bxor $gen[$j]
            $nxt[$j + 1] = $nxt[$j + 1] -bxor (Get-QrGfMul $gen[$j] $script:QrExp[$i])
        }
        $gen = $nxt
    }
    $rem = New-Object 'int[]' $n
    foreach ($b in $data) {
        $f = $b -bxor $rem[0]
        for ($i = 0; $i -lt $n - 1; $i++) { $rem[$i] = $rem[$i + 1] }
        $rem[$n - 1] = 0
        if ($f -ne 0) {
            for ($i = 0; $i -lt $n; $i++) {
                $rem[$i] = $rem[$i] -bxor (Get-QrGfMul $gen[$i + 1] $f)
            }
        }
    }
    return , $rem
}

function Get-QrCapacity([int]$ver) {
    $sum = 0
    foreach ($n in $script:QrBlocks[$ver]) { $sum += $n }
    return $sum
}

function Get-QrVersion([string]$text) {
    for ($ver = 1; $ver -le 10; $ver++) {
        $cc = 9
        if ($ver -ge 10) { $cc = 11 }
        $half = [int][math]::Floor($text.Length / 2)
        $nbits = 4 + $cc + $half * 11 + ($text.Length % 2) * 6
        if ($nbits -le (Get-QrCapacity $ver) * 8) { return $ver }
    }
    throw 'Text does not fit in QR versions 1-10 at level M.'
}

# Data codewords: mode, count, characters, terminator, padding
function Get-QrData([string]$text, [int]$ver) {
    $bits = New-Object 'System.Collections.Generic.List[int]'
    $put = {
        param([int]$val, [int]$n)
        for ($i = $n - 1; $i -ge 0; $i--) { $bits.Add(($val -shr $i) -band 1) }
    }
    & $put 2 4
    $cc = 9
    if ($ver -ge 10) { $cc = 11 }
    & $put $text.Length $cc
    $vals = New-Object 'int[]' $text.Length
    for ($i = 0; $i -lt $text.Length; $i++) { $vals[$i] = $script:QrAlnum.IndexOf($text[$i]) }
    for ($i = 0; $i + 1 -lt $vals.Length; $i += 2) { & $put ($vals[$i] * 45 + $vals[$i + 1]) 11 }
    if ($vals.Length % 2 -eq 1) { & $put $vals[$vals.Length - 1] 6 }
    $cap = (Get-QrCapacity $ver) * 8
    $term = [math]::Min(4, $cap - $bits.Count)
    for ($i = 0; $i -lt $term; $i++) { $bits.Add(0) }
    while ($bits.Count % 8 -ne 0) { $bits.Add(0) }
    $out = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $bits.Count; $i += 8) {
        $v = 0
        for ($j = 0; $j -lt 8; $j++) { $v = ($v -shl 1) -bor $bits[$i + $j] }
        $out.Add($v)
    }
    $pad = 0xEC
    while ($out.Count -lt $cap / 8) {
        $out.Add($pad)
        if ($pad -eq 0xEC) { $pad = 0x11 } else { $pad = 0xEC }
    }
    return , $out.ToArray()
}

# Split into blocks, add Reed-Solomon codewords, interleave
function Get-QrCodewords([int[]]$data, [int]$ver) {
    $ecLen = $script:QrEcLen[$ver]
    $lens = $script:QrBlocks[$ver]
    $blocks = @()
    $ecs = @()
    $pos = 0
    $maxLen = 0
    foreach ($n in $lens) {
        $blk = New-Object 'int[]' $n
        [array]::Copy($data, $pos, $blk, 0, $n)
        $pos += $n
        $blocks += , $blk
        $ecs += , (Get-QrRsRemainder $blk $ecLen)
        if ($n -gt $maxLen) { $maxLen = $n }
    }
    $out = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $maxLen; $i++) {
        foreach ($b in $blocks) { if ($i -lt $b.Length) { $out.Add($b[$i]) } }
    }
    for ($i = 0; $i -lt $ecLen; $i++) {
        foreach ($e in $ecs) { $out.Add($e[$i]) }
    }
    return , $out.ToArray()
}

function Get-QrFormatBits([int]$mask) {
    $data = $mask   # level M = 00
    $rem = $data
    for ($i = 0; $i -lt 10; $i++) {
        $rem = ($rem -shl 1) -bxor (($rem -shr 9) * 0x537)
    }
    return ((($data -shl 10) -bor $rem) -bxor 0x5412)
}

# Function-pattern state: $st.M modules, $st.F function-module flags, $st.Size
function Set-QrModule($st, [int]$x, [int]$y, [bool]$dark) {
    $st.M[$y][$x] = $dark
    $st.F[$y][$x] = $true
}

function Initialize-QrBase([int]$ver) {
    $size = $ver * 4 + 17
    $m = New-Object 'bool[][]' $size
    $f = New-Object 'bool[][]' $size
    for ($i = 0; $i -lt $size; $i++) {
        $m[$i] = New-Object 'bool[]' $size
        $f[$i] = New-Object 'bool[]' $size
    }
    $st = @{ M = $m; F = $f; Size = $size }
    for ($i = 0; $i -lt $size; $i++) {
        Set-QrModule $st 6 $i ($i % 2 -eq 0)
        Set-QrModule $st $i 6 ($i % 2 -eq 0)
    }
    foreach ($c in @(@(3, 3), @(($size - 4), 3), @(3, ($size - 4)))) {
        for ($dy = -4; $dy -le 4; $dy++) {
            for ($dx = -4; $dx -le 4; $dx++) {
                $x = $c[0] + $dx
                $y = $c[1] + $dy
                if ($x -ge 0 -and $x -lt $size -and $y -ge 0 -and $y -lt $size) {
                    $d = [math]::Max([math]::Abs($dx), [math]::Abs($dy))
                    Set-QrModule $st $x $y ($d -ne 2 -and $d -ne 4)
                }
            }
        }
    }
    $pos = $script:QrAlign[$ver]
    $n = $pos.Count
    for ($i = 0; $i -lt $n; $i++) {
        for ($j = 0; $j -lt $n; $j++) {
            if (($i -eq 0 -and $j -eq 0) -or ($i -eq 0 -and $j -eq $n - 1) -or ($i -eq $n - 1 -and $j -eq 0)) { continue }
            for ($dy = -2; $dy -le 2; $dy++) {
                for ($dx = -2; $dx -le 2; $dx++) {
                    $d = [math]::Max([math]::Abs($dx), [math]::Abs($dy))
                    Set-QrModule $st ($pos[$i] + $dx) ($pos[$j] + $dy) ($d -ne 1)
                }
            }
        }
    }
    return $st
}

function Set-QrFormat($st, [int]$mask, [bool]$blank) {
    $size = $st.Size
    $bits = 0
    if (-not $blank) { $bits = Get-QrFormatBits $mask }
    $bit = { param([int]$i) (($bits -shr $i) -band 1) -eq 1 }
    for ($i = 0; $i -le 5; $i++) { Set-QrModule $st 8 $i (& $bit $i) }
    Set-QrModule $st 8 7 (& $bit 6)
    Set-QrModule $st 8 8 (& $bit 7)
    Set-QrModule $st 7 8 (& $bit 8)
    for ($i = 9; $i -le 14; $i++) { Set-QrModule $st (14 - $i) 8 (& $bit $i) }
    for ($i = 0; $i -le 7; $i++) { Set-QrModule $st ($size - 1 - $i) 8 (& $bit $i) }
    for ($i = 8; $i -le 14; $i++) { Set-QrModule $st 8 ($size - 15 + $i) (& $bit $i) }
    Set-QrModule $st 8 ($size - 8) (-not $blank)   # dark module
}

function Set-QrVersionInfo($st, [int]$ver, [bool]$blank) {
    if ($ver -lt 7) { return }
    $size = $st.Size
    $rem = $ver
    for ($i = 0; $i -lt 12; $i++) {
        $rem = ($rem -shl 1) -bxor (($rem -shr 11) * 0x1F25)
    }
    $bits = 0
    if (-not $blank) { $bits = ($ver -shl 12) -bor $rem }
    for ($i = 0; $i -lt 18; $i++) {
        $d = (($bits -shr $i) -band 1) -eq 1
        $a = $size - 11 + ($i % 3)
        $b = [int][math]::Floor($i / 3)
        Set-QrModule $st $a $b $d
        Set-QrModule $st $b $a $d
    }
}

# Zigzag placement of codeword bits into the non-function modules
function Set-QrData($st, [int[]]$cw) {
    $size = $st.Size
    $total = $cw.Length * 8
    $k = 0
    for ($right = $size - 1; $right -ge 1; $right -= 2) {
        if ($right -eq 6) { $right = 5 }
        $upward = (($right + 1) -band 2) -eq 0
        for ($vert = 0; $vert -lt $size; $vert++) {
            for ($j = 0; $j -lt 2; $j++) {
                $x = $right - $j
                if ($upward) { $y = $size - 1 - $vert } else { $y = $vert }
                if ((-not $st.F[$y][$x]) -and $k -lt $total) {
                    $st.M[$y][$x] = ((($cw[$k -shr 3]) -shr (7 - ($k -band 7))) -band 1) -eq 1
                    $k++
                }
            }
        }
    }
}

function Test-QrMask([int]$mask, [int]$x, [int]$y) {
    switch ($mask) {
        0 { return (($x + $y) % 2) -eq 0 }
        1 { return ($y % 2) -eq 0 }
        2 { return ($x % 3) -eq 0 }
        3 { return (($x + $y) % 3) -eq 0 }
        4 { return (([int][math]::Floor($x / 3) + [int][math]::Floor($y / 2)) % 2) -eq 0 }
        5 { return ((($x * $y) % 2) + (($x * $y) % 3)) -eq 0 }
        6 { return (((($x * $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
        default { return (((($x + $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
    }
}

function Get-QrMasked($st, [int]$mask) {
    $size = $st.Size
    $m = New-Object 'bool[][]' $size
    for ($y = 0; $y -lt $size; $y++) {
        $row = [bool[]]$st.M[$y].Clone()
        for ($x = 0; $x -lt $size; $x++) {
            if ((-not $st.F[$y][$x]) -and (Test-QrMask $mask $x $y)) { $row[$x] = -not $row[$x] }
        }
        $m[$y] = $row
    }
    return , $m
}

# Pattern 1:1:3:1:1 (dark light dark dark dark light dark) with light modules
# (or the symbol edge) on one side
function Get-QrN3Score([bool[]]$line, [int]$size) {
    $pat = @($true, $false, $true, $true, $true, $false, $true)
    $score = 0
    $start = 0
    while ($true) {
        $idx = -1
        for ($i = $start; $i -le $size - 7; $i++) {
            $hit = $true
            for ($j = 0; $j -lt 7; $j++) {
                if ($line[$i + $j] -ne $pat[$j]) { $hit = $false; break }
            }
            if ($hit) { $idx = $i; break }
        }
        if ($idx -eq -1) { break }
        $off = $idx + 7
        $lightBefore = $true
        for ($i = [math]::Max($idx - 4, 0); $i -lt $idx; $i++) { if ($line[$i]) { $lightBefore = $false } }
        $lightAfter = $true
        for ($i = $off; $i -lt [math]::Min($off + 4, $size); $i++) { if ($line[$i]) { $lightAfter = $false } }
        if ($idx -eq 0 -or $idx -eq $size - 7 -or $lightBefore -or $lightAfter) {
            $score += 40
        } else {
            $off = $idx + 4
        }
        $start = $off
    }
    return $score
}

function Get-QrPenalty([bool[][]]$m, [int]$size) {
    $score = 0
    $dark = 0
    for ($pass = 0; $pass -lt 2; $pass++) {
        for ($a = 0; $a -lt $size; $a++) {
            $line = New-Object 'bool[]' $size
            for ($b = 0; $b -lt $size; $b++) {
                if ($pass -eq 0) { $line[$b] = $m[$a][$b] } else { $line[$b] = $m[$b][$a] }
            }
            $run = 1
            for ($i = 1; $i -lt $size; $i++) {
                if ($line[$i] -eq $line[$i - 1]) {
                    $run++
                } else {
                    if ($run -ge 5) { $score += $run - 2 }
                    $run = 1
                }
            }
            if ($run -ge 5) { $score += $run - 2 }
            $score += Get-QrN3Score $line $size
            if ($pass -eq 0) { foreach ($c in $line) { if ($c) { $dark++ } } }
        }
    }
    for ($y = 0; $y -lt $size - 1; $y++) {
        for ($x = 0; $x -lt $size - 1; $x++) {
            $c = $m[$y][$x]
            if ($c -eq $m[$y][$x + 1] -and $c -eq $m[$y + 1][$x] -and $c -eq $m[$y + 1][$x + 1]) { $score += 3 }
        }
    }
    $total = $size * $size
    $score += [int][math]::Floor([math]::Abs($dark * 20 - $total * 10) / $total) * 10
    return $score
}

# Returns @{ Matrix; Version; Mask }
function Get-QrCode([string]$Text) {
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($script:QrAlnum.IndexOf($Text[$i]) -lt 0) {
            throw ("Character not allowed in alphanumeric QR mode: '" + $Text[$i] + "'")
        }
    }
    Initialize-QrTables
    $ver = Get-QrVersion $Text
    $cw = Get-QrCodewords (Get-QrData $Text $ver) $ver
    $st = Initialize-QrBase $ver
    # format/version areas stay light while the masks are scored
    Set-QrFormat $st 0 $true
    Set-QrVersionInfo $st $ver $true
    Set-QrData $st $cw
    $bestScore = [int]::MaxValue
    $bestMask = 0
    $best = $null
    for ($mask = 0; $mask -lt 8; $mask++) {
        $m = Get-QrMasked $st $mask
        $p = Get-QrPenalty $m $st.Size
        if ($p -lt $bestScore) { $bestScore = $p; $bestMask = $mask; $best = $m }
    }
    $final = @{ M = $best; F = $st.F; Size = $st.Size }
    Set-QrFormat $final $bestMask $false
    Set-QrVersionInfo $final $ver $false
    return @{ Matrix = $final.M; Version = $ver; Mask = $bestMask }
}

function New-QrMatrix {
    param([Parameter(Mandatory = $true)][string]$Text)
    $code = Get-QrCode $Text
    return , $code.Matrix
}

function Write-QrConsole {
    param([Parameter(Mandatory = $true)][string]$Text)
    $m = New-QrMatrix -Text $Text
    $size = $m.Length
    $q = 4
    $n = $size + 2 * $q
    $full = [string][char]0x2588
    $upper = [string][char]0x2580
    $lower = [string][char]0x2584
    # light modules (and the quiet zone) are printed as blocks, dark modules as spaces
    $isLight = {
        param([int]$x, [int]$y)
        $xx = $x - $q
        $yy = $y - $q
        if ($xx -lt 0 -or $yy -lt 0 -or $xx -ge $size -or $yy -ge $size) { return $true }
        return (-not $m[$yy][$xx])
    }
    for ($y = 0; $y -lt $n; $y += 2) {
        $sb = New-Object System.Text.StringBuilder
        for ($x = 0; $x -lt $n; $x++) {
            $top = & $isLight $x $y
            $bot = $true
            if ($y + 1 -lt $n) { $bot = & $isLight $x ($y + 1) }
            if ($top -and $bot) { [void]$sb.Append($full) }
            elseif ($top) { [void]$sb.Append($upper) }
            elseif ($bot) { [void]$sb.Append($lower) }
            else { [void]$sb.Append(' ') }
        }
        Write-Host $sb.ToString()
    }
}
