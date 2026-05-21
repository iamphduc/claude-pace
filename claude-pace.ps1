#!/usr/bin/env pwsh
# Claude Code statusline (PowerShell port of claude-pace.sh).
# Line 1: model (ctx) effort | project (branch) Nf +A -D
# Line 2: bar PCT% CL | 5h used% [pace] countdown   7d used% [pace] countdown
#
# Requires PowerShell 7+. Reads stdin JSON, writes two color-aligned lines.
# Mirrors the invariants documented in CLAUDE.md.

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

# Force UTF-8 output so Unicode glyphs (▲▼ etc.) round-trip through Claude Code's
# stdout pipe and the terminal correctly. Without this, multi-byte UTF-8 bytes can
# get reinterpreted as the system OEM codepage and render as `?`.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$stdinRaw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($stdinRaw)) {   # bash $(cat) strips trailing newlines; mirror that
    [Console]::Out.WriteLine('Claude')
    exit 0
}

# ── Colors / constants ──
$E = [char]27
$C = "$E[36m"; $G = "$E[32m"; $Y = "$E[33m"; $R = "$E[31m"; $D = "$E[2m"; $B = "$E[1m"; $N = "$E[0m"
$SEP = [char]0x1F                                # ASCII Unit Separator
$NOW = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# ── Parse stdin + ~/.claude/settings.json ──
try {
    $in = $stdinRaw | ConvertFrom-Json -ErrorAction Stop
} catch {
    [Console]::Out.WriteLine('Claude [bad json]')
    exit 0
}

$cfg = $null
$settingsPath = Join-Path $HOME '.claude/settings.json'
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try { $cfg = (Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop } catch {}
}

$MODEL  = if ($in.model.display_name) { [string]$in.model.display_name } else { '?' }
$DIR    = if ($in.workspace.project_dir) { [string]$in.workspace.project_dir } else { '.' }
$PCT    = [int][math]::Floor([double]($in.context_window.used_percentage ?? 0))
$CTX    = [int]($in.context_window.context_window_size ?? 0)
$COST   = [double]($in.cost.total_cost_usd ?? 0)
$HAS_RL = $null -ne $in.rate_limits

$EFF_in  = $in.effort.level
$EFF_cfg = $cfg.effortLevel
$EFF = if ($EFF_in) { [string]$EFF_in } elseif ($EFF_cfg) { [string]$EFF_cfg } else { 'default' }
$EF = switch ($EFF) {
    'low'    { 'low' }
    'high'   { 'high' }
    'xhigh'  { 'xhigh' }
    'max'    { 'max' }
    default  { 'medium' }
}
# Effort gets its own color so it's distinguishable from the model (cyan).
# Intensity scale: low=dim → max=bold red.
$EF_COLOR = switch ($EF) {
    'low'    { $D }
    'medium' { $G }
    'high'   { $Y }
    'xhigh'  { $R }
    'max'    { "$B$R" }
    default  { $G }
}

$U5 = '--'; $U7 = '--'; $R5 = 0; $R7 = 0
if ($HAS_RL) {
    $u5raw = $in.rate_limits.five_hour.used_percentage
    $u7raw = $in.rate_limits.seven_day.used_percentage
    if ($u5raw -is [int] -or $u5raw -is [long] -or $u5raw -is [double]) { $U5 = [int][math]::Floor([double]$u5raw) }
    if ($u7raw -is [int] -or $u7raw -is [long] -or $u7raw -is [double]) { $U7 = [int][math]::Floor([double]$u7raw) }
    $R5 = [int]($in.rate_limits.five_hour.resets_at ?? 0)
    $R7 = [int]($in.rate_limits.seven_day.resets_at ?? 0)
}

# ── Context label (needed by MODEL_SHORT and line 2) ──
$CL = if ($CTX -ge 1000000) { "$([int]($CTX / 1000000))M" }
      elseif ($CTX -gt 0)   { "$([int]($CTX / 1000))K" }
      else                  { '' }

# ── MODEL_SHORT: strip redundant "(... context)" then optionally append (CL) ──
$MODEL = $MODEL -replace ' context\)', ')'
if ($CTX -gt 0 -and ($MODEL -notlike '*(*')) { $MODEL = "$MODEL ($CL)" }
# Cap "MODEL EF" left section at 28 chars (fits "Sonnet 4.6 (200K) medium" w/o ellipsis).
$ML = "$MODEL $EF"
if ($ML.Length -gt 28) {
    $cap = 28 - 4 - $EF.Length                   # 4 = "... " (ASCII ellipsis 3 + space 1)
    if ($cap -gt 0 -and $cap -lt $MODEL.Length) {
        $MODEL = $MODEL.Substring(0, $cap) + '...'
    }
}

# ── Progress bar ──
$F = [int][math]::Floor($PCT / 10)
if ($F -lt 0) { $F = 0 }
if ($F -gt 10) { $F = 10 }
$BC = if ($PCT -ge 90) { $R } elseif ($PCT -ge 70) { $Y } else { $G }
$BAR = ('#' * $F) + ('-' * (10 - $F))

# ── Cache directory probing (private, user-owned, not a reparse point) ──
function Test-SafeCacheDir {
    param([string]$path)
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $probe = Join-Path $path (".probe-$([guid]::NewGuid().ToString('N').Substring(0,8))")
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

$CACHE_OK = $false
$_CD = $null
$bases = @()
if ($env:XDG_RUNTIME_DIR) { $bases += $env:XDG_RUNTIME_DIR }
if ($env:LOCALAPPDATA)    { $bases += $env:LOCALAPPDATA }
if ($HOME)                { $bases += (Join-Path $HOME '.cache') }
foreach ($base in $bases) {
    $cand = Join-Path $base 'claude-pace'
    if (-not (Test-Path -LiteralPath $cand -PathType Container)) {
        try { New-Item -ItemType Directory -Path $cand -Force -ErrorAction Stop | Out-Null } catch { continue }
    }
    if (Test-SafeCacheDir $cand) { $_CD = $cand; $CACHE_OK = $true; break }
}

# ── Cache record helpers ──
function Read-CacheRecord {
    param([string]$line)
    if ($null -eq $line) { return @() }
    $line = $line -replace "`r?`n$", ''
    $delim = if ($line.Contains([string]$SEP)) { [string]$SEP } else { '|' }
    return $line.Split($delim)
}

function Save-CacheRecord {
    param([string]$path, [object[]]$fields)
    $dir = Split-Path -Parent $path
    $tmp = Join-Path $dir ("claude-sl-tmp-$([guid]::NewGuid().ToString('N').Substring(0,8))")
    try {
        $payload = (($fields | ForEach-Object { [string]$_ }) -join $SEP) + "`n"
        [IO.File]::WriteAllText($tmp, $payload)
        # Move-Item -Force replaces an existing target wholesale (incl. symlink), atomic on NTFS.
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        return $true
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Read-CacheFile {
    param([string]$path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }   # don't follow symlinks on read
        return Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    } catch { return $null }
}

function Get-MinutesUntil {
    param($epoch)
    $e = 0
    if (-not [int]::TryParse([string]$epoch, [ref]$e) -or $e -le 0) { return $null }
    $m = [int][math]::Floor(($e - $NOW) / 60.0)
    if ($m -lt 0) { $m = 0 }
    return $m
}

# ── Git metadata (with 5s cache, atomic write) ──
function Read-GitInfo {
    param([string]$dir)
    $r = [pscustomobject]@{ Branch = ''; FileCount = 0; Adds = 0; Dels = 0; Ok = $false }
    & git -C $dir rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $r }
    $br = & git -C $dir --no-optional-locks branch --show-current 2>$null
    if ($null -ne $br) { $r.Branch = ([string]$br).Trim() }

    # Tracked diff vs HEAD.
    $stats = & git -C $dir --no-optional-locks diff HEAD --numstat 2>$null
    if ($LASTEXITCODE -eq 0 -and $stats) {
        foreach ($line in $stats) {
            $cols = ([string]$line).Split("`t")
            if ($cols.Count -lt 2) { continue }
            $a = 0; $d = 0
            if ([int]::TryParse($cols[0], [ref]$a) -and [int]::TryParse($cols[1], [ref]$d)) {
                $r.FileCount++; $r.Adds += $a; $r.Dels += $d
            }
            # Binary files report "-" → skip silently, matching bash.
        }
    }

    # Untracked files (extends bash). Each untracked file is treated as a new file with all
    # its lines being additions — matching VS Code / GitHub diff conventions where new files
    # show as +N. ls-files respects .gitignore via --exclude-standard. Per-file size cap of
    # 1 MiB so a forgotten-to-ignore huge log doesn't dominate cache-refresh latency.
    $untracked = & git -C $dir --no-optional-locks ls-files --others --exclude-standard 2>$null
    if ($LASTEXITCODE -eq 0 -and $untracked) {
        foreach ($f in $untracked) {
            $path = Join-Path $dir ([string]$f)
            try {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                if (-not $item.PSIsContainer) {
                    $r.FileCount++
                    if ($item.Length -le 0 -or $item.Length -gt 1MB) { continue }
                    $bytes = [IO.File]::ReadAllBytes($path)
                    # Scan once: bail on NUL (binary), else count LFs.
                    $hasNul = $false; $lf = 0
                    foreach ($b in $bytes) {
                        if ($b -eq 0) { $hasNul = $true; break }
                        if ($b -eq 10) { $lf++ }
                    }
                    if ($hasNul) { continue }
                    $hasFinalNL = $bytes[$bytes.Length - 1] -eq 10
                    $r.Adds += if ($hasFinalNL) { $lf } else { $lf + 1 }
                }
            } catch {}
        }
    }

    $r.Ok = $true
    return $r
}

$BR = ''; $FC = 0; $AD = 0; $DL = 0
if ($CACHE_OK) {
    $sha = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($DIR))
    $hash = ($sha | ForEach-Object { $_.ToString('x2') }) -join ''
    $GC = Join-Path $_CD ("claude-sl-git-" + $hash.Substring(0, 16))
    $stale = $true
    if (Test-Path -LiteralPath $GC -PathType Leaf) {
        try {
            $age = $NOW - [int][DateTimeOffset]::new(((Get-Item -LiteralPath $GC).LastWriteTimeUtc)).ToUnixTimeSeconds()
            if ($age -le 5) { $stale = $false }
        } catch {}
    }
    if ($stale) {
        $info = Read-GitInfo $DIR
        if ($info.Ok) {
            Save-CacheRecord -path $GC -fields @($info.Branch, $info.FileCount, $info.Adds, $info.Dels) | Out-Null
            $BR = $info.Branch; $FC = $info.FileCount; $AD = $info.Adds; $DL = $info.Dels
        } else {
            Save-CacheRecord -path $GC -fields @('', '', '', '') | Out-Null
        }
    } else {
        $f = Read-CacheRecord (Read-CacheFile $GC)
        if ($f.Count -ge 4) {
            $BR = $f[0]
            $tmp = 0
            if ([int]::TryParse($f[1], [ref]$tmp)) { $FC = $tmp }
            if ([int]::TryParse($f[2], [ref]$tmp)) { $AD = $tmp }
            if ([int]::TryParse($f[3], [ref]$tmp)) { $DL = $tmp }
        }
    }
} else {
    $info = Read-GitInfo $DIR
    if ($info.Ok) { $BR = $info.Branch; $FC = $info.FileCount; $AD = $info.Adds; $DL = $info.Dels }
}

# ── Project name + Line 1 right section ──
$PN = Split-Path -Leaf $DIR
$IS_WT = $false; $repoName = ''; $wtName = ''
$normDir = $DIR -replace '\\', '/'
if ($normDir -match '/([^/]+)/\.claude/worktrees/([^/]+)') {
    $IS_WT = $true; $repoName = $Matches[1]; $wtName = $Matches[2]; $PN = $repoName
}
if ($PN.Length -gt 25) { $PN = $PN.Substring(0, 25) + '...' }

$L1R = $PN
if ($BR) {
    if ($BR.Length -gt 35) { $BR = $BR.Substring(0, 35) + '...' }
    $L1R = "$L1R ($BR)"
    if ($FC -gt 0) { $L1R = "$L1R ${FC}f $G+$AD$N $R-$DL$N" }
} elseif ($IS_WT) {
    $L1R = "$repoName/$wtName"
    if ($L1R.Length -gt 25) { $L1R = $L1R.Substring(0, 25) + '...' }
}

# ── Quota: stdin rate_limits only ──
# When rate_limits is absent we show placeholders and the session cost. No cache
# fallback: stdin carries no provider/account identifier, so a previous-run
# snapshot can't be proven to belong to the current session. See
# docs/decisions/2026-05-20-quota-cache-removal.md.
$SHOW_COST = $false
$RM5 = $null; $RM7 = $null
if ($HAS_RL) {
    $RM5 = Get-MinutesUntil $R5
    $RM7 = Get-MinutesUntil $R7
} else {
    $U5 = '--'; $U7 = '--'
    $SHOW_COST = $true
}

# ── Token count compact formatter ──
# Buckets: <1000 → "850", <1M → "<int>K" (e.g. 7K, 56K, 234K), ≥1M → "<int>M".
function Format-Tokens {
    param([int]$t)
    if ($t -lt 1000) { return [string]$t }
    if ($t -lt 1000000) { return "$([int][math]::Floor($t / 1000))K" }
    return "$([int][math]::Floor($t / 1000000))M"
}
$TOKENS = if ($CTX -gt 0) { [int][math]::Floor(($PCT / 100.0) * $CTX) } else { -1 }
$TOK = if ($TOKENS -ge 0) { ' ' + (Format-Tokens $TOKENS) } else { '' }

# ── Usage formatter: "used% [pace] countdown" ──
function Format-Usage {
    param($u, $rm, [int]$w)
    $sb = [System.Text.StringBuilder]::new()
    if ($u -isnot [int]) {
        [void]$sb.Append([string]$u)
    } else {
        $color = if ($u -ge 90) { $R } elseif ($u -ge 70) { $Y } else { $G }
        [void]$sb.Append("$B$color$u%$N")              # bold so the primary % is the headline
        if ($null -ne $rm -and $rm -is [int] -and $rm -le $w) {
            # Pace delta: positive = overspend (+N% red), negative = surplus (-N% green), zero = no marker.
            # Wrapped in parens to visually group with the % they qualify; pure ASCII signs avoid
            # the Unicode-glyph rendering issues seen with arrows in some Windows terminals/fonts.
            $delta = $u - [int][math]::Floor((($w - $rm) * 100.0) / $w)
            if ($delta -gt 0) { [void]$sb.Append(" $R(+$delta%)$N") }
            elseif ($delta -lt 0) { [void]$sb.Append(" $G(-$([math]::Abs($delta))%)$N") }
        }
    }
    if ($null -ne $rm -and $rm -is [int]) {
        # Compound countdown so the next-finer unit is visible:
        #   <60 min          →  "Nm"
        #   60..1439 min     →  "Nh Mm" (drops "Mm" when minutes==0)
        #   ≥1440 min (1d+)  →  "Nd Nh" (drops "Nh" when hours==0; minutes drop at this scale)
        # Locals are spelled out (not $d/$h/$m): PowerShell variable names are case-INSENSITIVE,
        # and a local $d would shadow the global $D dim-color, producing "22d 5h" with no dim.
        if ($rm -ge 1440) {
            $days = [int][math]::Floor($rm / 1440)
            $hours = [int][math]::Floor(($rm % 1440) / 60)
            $part = if ($hours -gt 0) { "${days}d${hours}h" } else { "${days}d" }
            [void]$sb.Append(" $D$part$N")
        }
        elseif ($rm -ge 60) {
            $hours = [int][math]::Floor($rm / 60)
            $mins = $rm % 60
            $part = if ($mins -gt 0) { "${hours}h${mins}m" } else { "${hours}h" }
            [void]$sb.Append(" $D$part$N")
        }
        else { [void]$sb.Append(" $D${rm}m$N") }
    }
    return $sb.ToString()
}

# ── Output assembly (symmetric single-pipe alignment) ──
$L1_PLAIN = "$MODEL $EF"
$L2_PLAIN = "[$BAR] $PCT%$TOK"                # token count counts toward width for pipe alignment
# Single source of truth for the visual gap around the | separator. Used both to compute
# left-side padding (so the longer content sits GAP chars before |) and to render the
# right-side padding (GAP chars between | and the right content). Same value on both sides
# means the pipe is visually balanced.
$GAP = 2
$RGAP = ' ' * $GAP
$LEFT_TARGET = [math]::Max($L1_PLAIN.Length, $L2_PLAIN.Length) + $GAP
$PAD1 = ' ' * ($LEFT_TARGET - $L1_PLAIN.Length)
$PAD2 = ' ' * ($LEFT_TARGET - $L2_PLAIN.Length)

$L1 = "$C$MODEL$N $EF_COLOR$EF$N$PAD1$D|$N$RGAP$L1R"

$U5fmt = Format-Usage -u $U5 -rm $RM5 -w 300
$U7fmt = Format-Usage -u $U7 -rm $RM7 -w 10080
# Brackets share the bar's threshold color (BC) so [bar] is one continuous color span.
# Token count rendered dim so the percent reads as the headline number.
$L2 = "$BC[$BAR]$N $PCT%$D$TOK$N$PAD2$D|$N${RGAP}5h: $U5fmt $D|$N 7d: $U7fmt"

if ($SHOW_COST) {
    $costStr = '${0:F2}' -f $COST
    if ($costStr -ne '$0.00') { $L2 = "$L2  $costStr" }
}

[Console]::Out.WriteLine($L1)
[Console]::Out.WriteLine($L2)
