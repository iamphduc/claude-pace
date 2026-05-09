#!/usr/bin/env pwsh
# Regression tests for claude-pace.ps1 (mirrors test.sh, custom harness, no Pester).
# Usage: pwsh -NoProfile -File test.ps1
# Exits non-zero on any failure; exit code = number of failures.
$ErrorActionPreference = 'Continue'

# Force UTF-8 throughout. Without this, capturing the child pwsh's stdout decodes with the
# system OEM codepage (cp437/cp1252), turning Unicode chars (⇡⇣█░…) into mojibake that
# breaks the regex assertions. The statusline output itself is fine; only the test capture
# is affected. Setting both encodings on the parent makes child capture round-trip cleanly.
$OutputEncoding             = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding   = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding    = [System.Text.UTF8Encoding]::new($false)
$script:RepoDir    = $PSScriptRoot
$script:ScriptPath = Join-Path $script:RepoDir 'claude-pace.ps1'
$script:Pass = 0
$script:Fail = 0
$script:CurrentOutput = @()

$script:TestTmp = Join-Path ([IO.Path]::GetTempPath()) "claude-pace-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $script:TestTmp -Force | Out-Null
trap { Remove-Item -LiteralPath $script:TestTmp -Recurse -Force -ErrorAction SilentlyContinue; throw }

# ── Helpers ──
function Strip-Ansi { param([string]$s) if ($null -eq $s) { return '' }; return ($s -replace "`e\[[0-9;]*m", '') }
function Output-Line { param([int]$n) if ($n -lt 1 -or $n -gt $script:CurrentOutput.Count) { return '' }; return $script:CurrentOutput[$n - 1] }

function Assert-LineMatch {
    param([string]$Name, [int]$LineNum, [string]$Pattern, [int]$Expect = 1)
    $actual = Output-Line $LineNum
    $matched = if ($actual -match $Pattern) { 1 } else { 0 }
    if ($matched -eq $Expect) {
        $script:Pass++; Write-Host "  PASS: $Name"
    } else {
        $script:Fail++; Write-Host "  FAIL: $Name"
        if ($Expect -eq 1) {
            Write-Host "    expected pattern: $Pattern"
            Write-Host "    actual:           $actual"
        } else {
            Write-Host "    unexpected pattern: $Pattern"
            Write-Host "    actual:             $actual"
        }
    }
}
function Assert-Line    { param([string]$N, [int]$L, [string]$P) Assert-LineMatch $N $L $P 1 }
function Assert-LineNot { param([string]$N, [int]$L, [string]$P) Assert-LineMatch $N $L $P 0 }

function Assert-Aligned {
    param([string]$Name)
    $l1 = Output-Line 1; $l2 = Output-Line 2
    $c1 = $l1.IndexOf('|'); $c2 = $l2.IndexOf('|')
    if ($c1 -ge 0 -and $c1 -eq $c2) {
        $script:Pass++; Write-Host "  PASS: $Name (col $c1)"
    } else {
        $script:Fail++; Write-Host "  FAIL: $Name (L1=$c1 L2=$c2)"
    }
}

function Assert-MissingPath {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $script:Pass++; Write-Host "  PASS: $Name"
    } else {
        $script:Fail++; Write-Host "  FAIL: $Name (path exists: $Path)"
    }
}

function Assert-LineCount {
    param([string]$Name, [int]$Expected)
    $actual = $script:CurrentOutput.Count
    if ($actual -eq $Expected) {
        $script:Pass++; Write-Host "  PASS: $Name"
    } else {
        $script:Fail++; Write-Host "  FAIL: $Name (expected $Expected, got $actual)"
    }
}

function Assert-True {
    param([string]$Name, [bool]$Cond)
    if ($Cond) { $script:Pass++; Write-Host "  PASS: $Name" } else { $script:Fail++; Write-Host "  FAIL: $Name" }
}

# Run claude-pace.ps1 with isolated env. Returns ANSI-stripped lines.
function Invoke-Statusline {
    param([string]$Json, [hashtable]$Env = @{})
    $keys  = @('HOME', 'USERPROFILE', 'XDG_RUNTIME_DIR', 'LOCALAPPDATA')
    $saved = @{}
    foreach ($k in $keys) { $saved[$k] = (Get-Item -Path "Env:$k" -ErrorAction SilentlyContinue).Value }
    try {
        foreach ($k in $Env.Keys) {
            if ($null -eq $Env[$k] -or $Env[$k] -eq '') {
                Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path "Env:$k" -Value $Env[$k]
            }
        }
        $out = $Json | & pwsh -NoProfile -File $script:ScriptPath 2>$null
        $lines = if ($null -eq $out) { @() } elseif ($out -is [string]) { @($out) } else { @($out) }
        $stripped = @($lines | ForEach-Object { Strip-Ansi $_ })
        # Use NoEnumerate to keep this an array even when length 1; otherwise PS auto-unwraps
        # and a downstream $arr[0] on a string returns its first character.
        Write-Output -NoEnumerate $stripped
    } finally {
        foreach ($k in $keys) {
            if ($null -eq $saved[$k]) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "Env:$k" -Value $saved[$k] }
        }
    }
}
function Invoke-SideEffect { param([string]$Json, [hashtable]$Env = @{}) Invoke-Statusline -Json $Json -Env $Env | Out-Null }

function Hash-Dir { param([string]$Dir)
    $sha = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir))
    return (($sha | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}
function Get-GitCachePath   { param([string]$Root, [string]$Dir) Join-Path $Root ('claude-sl-git-' + (Hash-Dir $Dir)) }
function Get-QuotaCachePath { param([string]$Root) Join-Path $Root 'claude-sl-quota' }

function Init-TestRepo {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -b main *>$null
    & git -C $Path config user.name tester *>$null
    & git -C $Path config user.email tester@example.com *>$null
    Set-Content -LiteralPath (Join-Path $Path 'readme.txt') -Value 'ok' -NoNewline
    & git -C $Path add readme.txt *>$null
    & git -C $Path commit -m init *>$null
}

# JSON path helper: claude-pace expects forward-slash paths in workspace.project_dir.
function Norm { param([string]$p) ($p -replace '\\', '/') }

$NOW = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$RepoName = Split-Path -Leaf $script:RepoDir
$CurrentBranch = (& git -C $script:RepoDir branch --show-current 2>$null).Trim()
$RDIR = Norm $script:RepoDir

# ── Test 1: MODEL_SHORT strips "(1M context)" → "(1M)" ──
Write-Host "Test 1: MODEL_SHORT"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":16,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":17,`"resets_at`":$($NOW+2580)},`"seven_day`":{`"used_percentage`":21,`"resets_at`":$($NOW+345600)}}}"
Assert-Line "model shows (1M) not (1M context)" 1 'Opus 4\.6 \(1M\)'
Assert-Line "no brackets around model" 1 '^Opus'

# ── Test 2: Model without context in name gets (CL) appended ──
Write-Host "Test 2: MODEL_SHORT append"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Sonnet 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":50,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":57,`"resets_at`":$($NOW+7200)},`"seven_day`":{`"used_percentage`":35,`"resets_at`":$($NOW+432000)}}}"
Assert-Line "appends (200K)" 1 'Sonnet 4\.6 \(200K\)'

# ── Test 3: CTX=0 should NOT append "(0K)" ──
Write-Host "Test 3: CTX=0 guard"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":0,`"context_window_size`":0}}"
Assert-Line "no (0K) in model" 1 '^Opus 4\.6 [^(]'

# ── Test 4: Branch in parentheses ──
Write-Host "Test 4: branch format"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":16,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":17,`"resets_at`":$($NOW+2580)},`"seven_day`":{`"used_percentage`":21,`"resets_at`":$($NOW+345600)}}}"
if ($CurrentBranch) {
    Assert-Line "branch in parens ($CurrentBranch)" 1 "\($([regex]::Escape($CurrentBranch))\)"
} else {
    Assert-Line "no branch suffix in detached HEAD" 1 "\|  $([regex]::Escape($RepoName))$"
}
Assert-Line "project name only" 1 ([regex]::Escape($RepoName))

# ── Test 5: Pipe alignment ──
Write-Host "Test 5: pipe alignment"
Assert-Aligned "| aligned between lines"

# ── Test 6: Line 2 format ──
Write-Host "Test 6: line 2 format"
Assert-Line "two pipes on L2 (central + inter-window)" 2 '^[^|]+\|[^|]+\|[^|]*$'
Assert-Line "5h label has colon" 2 '5h: [0-9]'
Assert-Line "7d label has colon" 2 '7d: [0-9]'
Assert-Line "no parens on countdown" 2 '[0-9]+[dhm][^)]'
Assert-Line "bar then percent on L2"      2 '^\S+ [0-9]+%'

# ── Test 7: Different model alignment ──
Write-Host "Test 7: Sonnet alignment"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Sonnet 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":50,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":57,`"resets_at`":$($NOW+7200)},`"seven_day`":{`"used_percentage`":35,`"resets_at`":$($NOW+432000)}}}"
Assert-Aligned "| aligned for Sonnet"

# ── Test 8: 100% context alignment ──
Write-Host "Test 8: 100% context alignment"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":100,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":92,`"resets_at`":$($NOW+600)},`"seven_day`":{`"used_percentage`":79,`"resets_at`":$($NOW+172800)}}}"
Assert-Aligned "| aligned at 100%"

# ── Test 9: Worktree path ──
Write-Host "Test 9: worktree"
$WT = Norm (Join-Path $script:RepoDir '.claude/worktrees/fix-auth')
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$WT`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}"
Assert-Line "worktree shows repo name" 1 ([regex]::Escape($RepoName))

# ── Test 10: Long model name truncation ──
Write-Host "Test 10: long model truncation"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"claude-3-opus-20240229-extended`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":25,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":20,`"resets_at`":$($NOW+14000)},`"seven_day`":{`"used_percentage`":10,`"resets_at`":$($NOW+500000)}}}"
Assert-Aligned "| aligned for long model"

# ── Test 11: Pace delta arrows (boundary values) ──
Write-Host "Test 11: pace delta"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":51,`"resets_at`":$($NOW+9000)},`"seven_day`":{`"used_percentage`":50,`"resets_at`":$($NOW+302400)}}}"
Assert-Line "+1% shown for min overspend" 2 '5h: 51% \(\+1%\)'
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":49,`"resets_at`":$($NOW+9000)},`"seven_day`":{`"used_percentage`":50,`"resets_at`":$($NOW+302400)}}}"
Assert-Line "-1% shown for min surplus" 2 '5h: 49% \(-1%\)'
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":50,`"resets_at`":$($NOW+9000)},`"seven_day`":{`"used_percentage`":50,`"resets_at`":$($NOW+302400)}}}"
Assert-Line "no arrow at d=0" 2 '5h: 50% [0-9]'

# ── Test 11b: Compound countdown — days+hours / hours+minutes formats ──
# Catches the $d-vs-$D case-insensitive variable collision that produced "22d 5h" (with no dim)
# instead of "2d 5h".
Write-Host "Test 11b: compound countdown format"
$reset5h = $NOW + (1 * 3600) + (32 * 60)         # 1h 32m
$reset7d = $NOW + (2 * 86400) + (5 * 3600)       # 2d 5h
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6 (1M context)`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":1000000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":40,`"resets_at`":$reset5h},`"seven_day`":{`"used_percentage`":50,`"resets_at`":$reset7d}}}"
Assert-Line    "5h shows hours+minutes format"   2 '\d+h\d+m'
Assert-Line    "7d shows days+hours format"      2 '\d+d\d+h'
Assert-LineNot "no doubled-digit days bug"       2 '22d'

# ── Test 12: Cache record with newlines must not break output ──
Write-Host "Test 12: branch cache newline injection"
$INJECT_HOME    = Join-Path $script:TestTmp 'inject-home'
$INJECT_RUNTIME = Join-Path $script:TestTmp 'inject-runtime'
$INJECT_DIR     = Join-Path $script:TestTmp 'non-git-escape'
$INJECT_ROOT    = Join-Path $INJECT_RUNTIME 'claude-pace'
$null = New-Item -ItemType Directory -Path $INJECT_HOME, $INJECT_RUNTIME, $INJECT_DIR, $INJECT_ROOT -Force
Set-Content -LiteralPath (Get-GitCachePath $INJECT_ROOT $INJECT_DIR) -Value "feature`nPWN|0|0|0" -NoNewline
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$(Norm $INJECT_DIR)`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $INJECT_HOME; USERPROFILE = $INJECT_HOME; XDG_RUNTIME_DIR = $INJECT_RUNTIME }
Assert-LineCount "branch cache keeps output to two lines" 2

# Test 13 (bash arithmetic injection) skipped — PowerShell port uses [int]::TryParse for all cache fields,
# which strictly validates and rejects any non-numeric content. The attack vector doesn't exist.

# ── Test 14: Different cache root isolates from foreign poisoning ──
Write-Host "Test 14: isolated cache root ignores foreign cache"
$PRIVATE_HOME    = Join-Path $script:TestTmp 'private-home'
$PRIVATE_RUNTIME = Join-Path $script:TestTmp 'private-runtime'
$PRIVATE_REPO    = Join-Path $script:TestTmp 'private-repo'
$null = New-Item -ItemType Directory -Path $PRIVATE_HOME, $PRIVATE_RUNTIME -Force
Init-TestRepo $PRIVATE_REPO
# Poison a *different* runtime dir to confirm it isn't picked up.
$FOREIGN = Join-Path $script:TestTmp 'foreign-runtime/claude-pace'
$null = New-Item -ItemType Directory -Path $FOREIGN -Force
Set-Content -LiteralPath (Get-GitCachePath $FOREIGN $PRIVATE_REPO) -Value 'evil|0|0|0' -NoNewline
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$(Norm $PRIVATE_REPO)`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $PRIVATE_HOME; USERPROFILE = $PRIVATE_HOME; XDG_RUNTIME_DIR = $PRIVATE_RUNTIME }
$joined = ($script:CurrentOutput -join "`n")
Assert-True "private cache root ignores foreign cache" (($joined -match '\(main\)') -and ($joined -notmatch '\(evil\)'))

# ── Test 15: Branch names containing | survive cache round-trip ──
# Windows can't host a git branch named "feat|pipe" (NTFS doesn't allow | in filenames),
# so we test the cache-record format directly: pre-populate the cache file with a pipe in
# the branch field, and verify the script reads it back faithfully (no | / SEP confusion).
Write-Host "Test 15: branch names containing pipes"
$PIPE_HOME    = Join-Path $script:TestTmp 'pipe-home'
$PIPE_RUNTIME = Join-Path $script:TestTmp 'pipe-runtime'
$PIPE_DIR     = Join-Path $script:TestTmp 'pipe-dir'
$PIPE_ROOT    = Join-Path $PIPE_RUNTIME 'claude-pace'
$null = New-Item -ItemType Directory -Path $PIPE_HOME, $PIPE_ROOT, $PIPE_DIR -Force
$SEPCH = [char]0x1F
# Hash the SAME path the script will see (forward-slash form, since JSON sends it normalized).
$PIPE_DIR_NORM = Norm $PIPE_DIR
[IO.File]::WriteAllText((Get-GitCachePath $PIPE_ROOT $PIPE_DIR_NORM), "feat|pipe${SEPCH}0${SEPCH}0${SEPCH}0`n")
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$PIPE_DIR_NORM`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $PIPE_HOME; USERPROFILE = $PIPE_HOME; XDG_RUNTIME_DIR = $PIPE_RUNTIME }
$joined = ($script:CurrentOutput -join "`n")
Assert-True "cache preserves branch names containing pipes" ($joined -match '\(feat\|pipe\)')

# ── Test 17: Hash cache key collision resistance ──
Write-Host "Test 17: hash cache key collision resistance"
$DIR_A = Join-Path $script:TestTmp 'coll-a/b'
$DIR_B = Join-Path $script:TestTmp 'coll-a-b'
$null = New-Item -ItemType Directory -Path $DIR_A, $DIR_B -Force
Assert-True "different dirs produce different cache keys" ((Hash-Dir $DIR_A) -ne (Hash-Dir $DIR_B))

# ── Test 19: Live rate_limits writes quota cache ──
Write-Host "Test 19: live rate_limits writes quota cache"
$QUOTA_HOME    = Join-Path $script:TestTmp 'quota-home'
$QUOTA_RUNTIME = Join-Path $script:TestTmp 'quota-runtime'
$QUOTA_ROOT    = Join-Path $QUOTA_RUNTIME 'claude-pace'
$null = New-Item -ItemType Directory -Path $QUOTA_HOME, $QUOTA_RUNTIME -Force
Invoke-SideEffect -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $QUOTA_HOME; USERPROFILE = $QUOTA_HOME; XDG_RUNTIME_DIR = $QUOTA_RUNTIME }
Assert-True "quota cache file created from live rate_limits" (Test-Path -LiteralPath (Get-QuotaCachePath $QUOTA_ROOT))

# ── Test 20: Missing rate_limits reuses cached quota and suppresses cost ──
Write-Host "Test 20: missing rate_limits reuses cached quota"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $QUOTA_HOME; USERPROFILE = $QUOTA_HOME; XDG_RUNTIME_DIR = $QUOTA_RUNTIME }
Assert-Line    "cached 5h quota shown"               2 '5h: 30%'
Assert-Line    "cached 7d quota shown"               2 '7d: 15%'
Assert-LineNot "cached quota suppresses session cost" 2 '\$1\.23'

# ── Test 21: Invalid quota cache degrades to no-quota fallback ──
Write-Host "Test 21: invalid quota cache degrades cleanly"
$BAD_HOME    = Join-Path $script:TestTmp 'bad-home'
$BAD_RUNTIME = Join-Path $script:TestTmp 'bad-runtime'
$BAD_ROOT    = Join-Path $BAD_RUNTIME 'claude-pace'
$null = New-Item -ItemType Directory -Path $BAD_HOME, $BAD_ROOT -Force
Set-Content -LiteralPath (Get-QuotaCachePath $BAD_ROOT) -Value 'abc|15|9999999999|9999999999' -NoNewline
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $BAD_HOME; USERPROFILE = $BAD_HOME; XDG_RUNTIME_DIR = $BAD_RUNTIME }
Assert-Line "invalid cache falls back to no quota 5h" 2 '5h: --'
Assert-Line "invalid cache falls back to no quota 7d" 2 '7d: --'
Assert-Line "invalid cache keeps session cost"        2 '\$1\.23'

# ── Test 22: Safe cache root with no quota file degrades to no-quota fallback ──
Write-Host "Test 22: safe cache root without quota cache file"
$EMPTY_HOME    = Join-Path $script:TestTmp 'empty-home'
$EMPTY_RUNTIME = Join-Path $script:TestTmp 'empty-runtime'
$null = New-Item -ItemType Directory -Path $EMPTY_HOME, $EMPTY_RUNTIME -Force
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $EMPTY_HOME; USERPROFILE = $EMPTY_HOME; XDG_RUNTIME_DIR = $EMPTY_RUNTIME }
Assert-Line "safe cache root without file keeps 5h --"           2 '5h: --'
Assert-Line "safe cache root without file keeps 7d --"           2 '7d: --'
Assert-Line "safe cache root without file keeps session cost"    2 '\$1\.23'

# ── Test 23: Partial live missing five_hour does not overwrite cache ──
Write-Host "Test 23: partial live missing five_hour"
$PARTIAL_HOME    = Join-Path $script:TestTmp 'partial-home'
$PARTIAL_RUNTIME = Join-Path $script:TestTmp 'partial-runtime'
$null = New-Item -ItemType Directory -Path $PARTIAL_HOME, $PARTIAL_RUNTIME -Force
Invoke-SideEffect -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $PARTIAL_HOME; USERPROFILE = $PARTIAL_HOME; XDG_RUNTIME_DIR = $PARTIAL_RUNTIME }
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23},`"rate_limits`":{`"seven_day`":{`"used_percentage`":18,`"resets_at`":$($NOW+400000)}}}" -Env @{ HOME = $PARTIAL_HOME; USERPROFILE = $PARTIAL_HOME; XDG_RUNTIME_DIR = $PARTIAL_RUNTIME }
Assert-Line    "partial live missing five_hour renders 5h --" 2 '5h: --'
Assert-Line    "partial live keeps live seven_day"            2 '7d: 18%'
Assert-LineNot "partial live does not show session cost"      2 '\$1\.23'
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $PARTIAL_HOME; USERPROFILE = $PARTIAL_HOME; XDG_RUNTIME_DIR = $PARTIAL_RUNTIME }
Assert-Line "cache survives missing five_hour partial live"                  2 '5h: 30%'
Assert-Line "cache keeps original seven_day after missing five_hour partial" 2 '7d: 15%'

# ── Test 24: Partial live missing five_hour.resets_at does not overwrite cache ──
Write-Host "Test 24: partial live missing five_hour resets_at"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23},`"rate_limits`":{`"five_hour`":{`"used_percentage`":31},`"seven_day`":{`"used_percentage`":18,`"resets_at`":$($NOW+400000)}}}" -Env @{ HOME = $PARTIAL_HOME; USERPROFILE = $PARTIAL_HOME; XDG_RUNTIME_DIR = $PARTIAL_RUNTIME }
Assert-Line    "partial live missing five_hour resets_at keeps 5h percent" 2 '5h: 31%'
Assert-LineNot "partial live missing five_hour resets_at hides cost"       2 '\$1\.23'
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $PARTIAL_HOME; USERPROFILE = $PARTIAL_HOME; XDG_RUNTIME_DIR = $PARTIAL_RUNTIME }
Assert-Line "cache survives missing five_hour resets_at"           2 '5h: 30%'
Assert-Line "cache keeps original seven_day after missing resets_at" 2 '7d: 15%'

# ── Test 25: Partial live missing seven_day does not overwrite cache ──
Write-Host "Test 25: partial live missing seven_day"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23},`"rate_limits`":{`"five_hour`":{`"used_percentage`":29,`"resets_at`":$($NOW+11000)}}}" -Env @{ HOME = $PARTIAL_HOME; USERPROFILE = $PARTIAL_HOME; XDG_RUNTIME_DIR = $PARTIAL_RUNTIME }
Assert-Line    "partial live keeps live five_hour"           2 '5h: 29%'
Assert-Line    "partial live missing seven_day renders 7d --" 2 '7d: --'
Assert-LineNot "partial live missing seven_day hides cost"    2 '\$1\.23'
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $PARTIAL_HOME; USERPROFILE = $PARTIAL_HOME; XDG_RUNTIME_DIR = $PARTIAL_RUNTIME }
Assert-Line "cache keeps original five_hour after missing seven_day" 2 '5h: 30%'
Assert-Line "cache survives missing seven_day partial live"          2 '7d: 15%'

# ── Test 26: Expired live snapshot does not overwrite a good cache ──
Write-Host "Test 26: expired live snapshot does not overwrite cache"
$LE_HOME    = Join-Path $script:TestTmp 'live-expired-home'
$LE_RUNTIME = Join-Path $script:TestTmp 'live-expired-runtime'
$null = New-Item -ItemType Directory -Path $LE_HOME, $LE_RUNTIME -Force
Invoke-SideEffect -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $LE_HOME; USERPROFILE = $LE_HOME; XDG_RUNTIME_DIR = $LE_RUNTIME }
Invoke-SideEffect -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":99,`"resets_at`":$NOW},`"seven_day`":{`"used_percentage`":66,`"resets_at`":$($NOW+400000)}}}" -Env @{ HOME = $LE_HOME; USERPROFILE = $LE_HOME; XDG_RUNTIME_DIR = $LE_RUNTIME }
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $LE_HOME; USERPROFILE = $LE_HOME; XDG_RUNTIME_DIR = $LE_RUNTIME }
Assert-Line "expired live R5 keeps cached five_hour" 2 '5h: 30%'
Assert-Line "expired live R5 keeps cached seven_day" 2 '7d: 15%'
Invoke-SideEffect -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $LE_HOME; USERPROFILE = $LE_HOME; XDG_RUNTIME_DIR = $LE_RUNTIME }
Invoke-SideEffect -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":66,`"resets_at`":$($NOW+11000)},`"seven_day`":{`"used_percentage`":99,`"resets_at`":$NOW}}}" -Env @{ HOME = $LE_HOME; USERPROFILE = $LE_HOME; XDG_RUNTIME_DIR = $LE_RUNTIME }
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $LE_HOME; USERPROFILE = $LE_HOME; XDG_RUNTIME_DIR = $LE_RUNTIME }
Assert-Line "expired live R7 keeps cached five_hour" 2 '5h: 30%'
Assert-Line "expired live R7 keeps cached seven_day" 2 '7d: 15%'

# ── Test 27: Expired quota cache is rejected wholesale ──
Write-Host "Test 27: expired quota cache is rejected"
$EX_HOME    = Join-Path $script:TestTmp 'expired-home'
$EX_RUNTIME = Join-Path $script:TestTmp 'expired-runtime'
$EX_ROOT    = Join-Path $EX_RUNTIME 'claude-pace'
$null = New-Item -ItemType Directory -Path $EX_HOME, $EX_ROOT -Force
Set-Content -LiteralPath (Get-QuotaCachePath $EX_ROOT) -Value "30|15|$NOW|$($NOW + 500000)" -NoNewline
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $EX_HOME; USERPROFILE = $EX_HOME; XDG_RUNTIME_DIR = $EX_RUNTIME }
Assert-Line "expired R5 rejects whole snapshot"     2 '5h: --'
Assert-Line "expired R5 also rejects cached 7d"     2 '7d: --'
Assert-Line "expired R5 keeps session cost"         2 '\$1\.23'
Set-Content -LiteralPath (Get-QuotaCachePath $EX_ROOT) -Value "30|15|$($NOW + 12000)|$NOW" -NoNewline
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $EX_HOME; USERPROFILE = $EX_HOME; XDG_RUNTIME_DIR = $EX_RUNTIME }
Assert-Line "expired R7 also rejects cached 5h"     2 '5h: --'
Assert-Line "expired R7 rejects whole snapshot"     2 '7d: --'
Assert-Line "expired R7 keeps session cost"         2 '\$1\.23'

# ── Test 28: Empty stdin stays Claude ──
Write-Host "Test 28: empty stdin still returns Claude"
$script:CurrentOutput = Invoke-Statusline -Json ''
Assert-LineCount "empty stdin stays single line" 1
Assert-Line      "empty stdin prints Claude"     1 '^Claude$'

# ── Test 29: No safe cache root degrades cleanly ──
# Force every cache-root candidate at a path that can't be turned into a directory: an
# existing FILE. New-Item on `<file>/claude-pace` fails because the parent isn't a dir,
# so all three branches (XDG_RUNTIME_DIR / LOCALAPPDATA / $HOME/.cache) are rejected and
# CACHE_OK = $false.
Write-Host "Test 29: no safe cache root keeps session cost"
$NO_CACHE_FILE = Join-Path $script:TestTmp 'no-cache.file'
[IO.File]::WriteAllText($NO_CACHE_FILE, '')
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23}}" -Env @{ HOME = $NO_CACHE_FILE; USERPROFILE = $NO_CACHE_FILE; LOCALAPPDATA = $NO_CACHE_FILE; XDG_RUNTIME_DIR = '' }
Assert-Line "no quota source keeps 5h --"        2 '5h: --'
Assert-Line "no quota source keeps session cost" 2 '\$1\.23'

# ── Test 30: Explicit null rate_limits reuses cached quota ──
Write-Host "Test 30: explicit null rate_limits reuses cache"
$NULL_HOME    = Join-Path $script:TestTmp 'null-home'
$NULL_RUNTIME = Join-Path $script:TestTmp 'null-runtime'
$null = New-Item -ItemType Directory -Path $NULL_HOME, $NULL_RUNTIME -Force
Invoke-SideEffect -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}" -Env @{ HOME = $NULL_HOME; USERPROFILE = $NULL_HOME; XDG_RUNTIME_DIR = $NULL_RUNTIME }
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23},`"rate_limits`":null}" -Env @{ HOME = $NULL_HOME; USERPROFILE = $NULL_HOME; XDG_RUNTIME_DIR = $NULL_RUNTIME }
Assert-Line    "null rate_limits reuses cached 5h" 2 '5h: 30%'
Assert-Line    "null rate_limits reuses cached 7d" 2 '7d: 15%'
Assert-LineNot "null rate_limits suppresses cost"  2 '\$1\.23'

# ── Test 31: Empty-object rate_limits behaves like partial live data ──
Write-Host "Test 31: empty-object rate_limits uses live partial behavior"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"cost`":{`"total_cost_usd`":1.23},`"rate_limits`":{}}" -Env @{ HOME = $NULL_HOME; USERPROFILE = $NULL_HOME; XDG_RUNTIME_DIR = $NULL_RUNTIME }
Assert-Line    "empty-object rate_limits shows 5h --" 2 '5h: --'
Assert-Line    "empty-object rate_limits shows 7d --" 2 '7d: --'
Assert-LineNot "empty-object rate_limits hides cost"  2 '\$1\.23'

# ── Test 34: Effort level words for all five levels (settings.json source) ──
Write-Host "Test 34: effort level words"
$EF_HOME    = Join-Path $script:TestTmp 'effort-home'
$EF_RUNTIME = Join-Path $script:TestTmp 'effort-runtime'
$null = New-Item -ItemType Directory -Path (Join-Path $EF_HOME '.claude'), $EF_RUNTIME -Force
function Effort-Json {
    param([string]$Level)
    if ($Level) {
        return "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"effort`":{`"level`":`"$Level`"},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}"
    }
    return "{`"model`":{`"display_name`":`"Opus 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}"
}
foreach ($lvl in @('low','medium','high','xhigh','max')) {
    Set-Content -LiteralPath (Join-Path $EF_HOME '.claude/settings.json') -Value "{`"effortLevel`":`"$lvl`"}" -NoNewline
    $script:CurrentOutput = Invoke-Statusline -Json (Effort-Json '') -Env @{ HOME = $EF_HOME; USERPROFILE = $EF_HOME; XDG_RUNTIME_DIR = $EF_RUNTIME }
    Assert-Line    "effort $lvl shows word"     1 " $lvl "
    Assert-Aligned "| aligned for effort $lvl"
}
Remove-Item -LiteralPath (Join-Path $EF_HOME '.claude/settings.json') -Force -ErrorAction SilentlyContinue
$script:CurrentOutput = Invoke-Statusline -Json (Effort-Json '') -Env @{ HOME = $EF_HOME; USERPROFILE = $EF_HOME; XDG_RUNTIME_DIR = $EF_RUNTIME }
Assert-Line "absent settings.json falls back to medium" 1 ' medium '

# ── Test 35: Effort level from stdin (CC ≥ 2.1.119) ──
Write-Host "Test 35: effort level from stdin"
$SE_HOME    = Join-Path $script:TestTmp 'stdin-effort-home'
$SE_RUNTIME = Join-Path $script:TestTmp 'stdin-effort-runtime'
$null = New-Item -ItemType Directory -Path (Join-Path $SE_HOME '.claude'), $SE_RUNTIME -Force
foreach ($lvl in @('low','medium','high','xhigh','max')) {
    $script:CurrentOutput = Invoke-Statusline -Json (Effort-Json $lvl) -Env @{ HOME = $SE_HOME; USERPROFILE = $SE_HOME; XDG_RUNTIME_DIR = $SE_RUNTIME }
    Assert-Line    "stdin effort $lvl shows word"     1 " $lvl "
    Assert-Aligned "| aligned for stdin effort $lvl"
}

# ── Test 36: Stdin effort.level overrides settings.json effortLevel ──
Write-Host "Test 36: stdin effort overrides settings"
Set-Content -LiteralPath (Join-Path $SE_HOME '.claude/settings.json') -Value '{"effortLevel":"low"}' -NoNewline
$script:CurrentOutput = Invoke-Statusline -Json (Effort-Json 'max') -Env @{ HOME = $SE_HOME; USERPROFILE = $SE_HOME; XDG_RUNTIME_DIR = $SE_RUNTIME }
Assert-Line    "stdin effort.level wins over settings" 1 ' max '
Assert-Aligned "| aligned with stdin override"

# ── Test 37: Truncation budget (28) fits longest word without ellipsis ──
Write-Host "Test 37: truncation budget fits longest word"
$script:CurrentOutput = Invoke-Statusline -Json "{`"model`":{`"display_name`":`"Sonnet 4.6`"},`"workspace`":{`"project_dir`":`"$RDIR`"},`"context_window`":{`"used_percentage`":20,`"context_window_size`":200000},`"effort`":{`"level`":`"medium`"},`"rate_limits`":{`"five_hour`":{`"used_percentage`":30,`"resets_at`":$($NOW+12000)},`"seven_day`":{`"used_percentage`":15,`"resets_at`":$($NOW+500000)}}}"
Assert-Line    "Sonnet 4.6 (200K) medium fits without ellipsis" 1 'Sonnet 4\.6 \(200K\) medium'
Assert-LineNot "no ellipsis on medium with mid-length model"    1 '\.\.\.'

# ── Summary ──
Write-Host ''
Write-Host "Results: $($script:Pass) passed, $($script:Fail) failed"
Remove-Item -LiteralPath $script:TestTmp -Recurse -Force -ErrorAction SilentlyContinue
exit $script:Fail
