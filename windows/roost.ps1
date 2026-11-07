#requires -Version 7
# roost - Claude Code sessions on Windows. Every session is a window of ONE psmux (tmux for Windows) session "roost":
# sessions keep running when you close the terminal / drop SSH, and a small registry lets them be reopened with
# --resume after a reboot / logon.
#
#   roost                                open the roost screen (psmux session "roost"; window "dash" lists the sessions)
#   roost ls                             list sessions
#   roost NAME                           open / switch to a session
#   roost new NAME [DIR] [claude args]   open a session window, e.g.  roost new api C:\src\api -c
#   roost restore [NAME]                 reopen parked sessions (parked = registered but its window is gone)
#   roost close NAME                     close the window and forget the session
#   roost forget NAME                    forget the registry entry only
#   roost doctor                         health check
#   roost selftest                       check the scripts without opening any window
#
# Registry: %LOCALAPPDATA%\roost\sessions\NAME.json, written by roost-hook.ps1 through Claude Code hooks.
# Only /exit or /logout forgets a session; closing the window or rebooting keeps it for `roost restore`.
# Env overrides: ROOST_HOME, ROOST_DRY=1 (print the psmux command instead of running it), ROOST_STAGGER (s), ROOST_NET_WAIT (s),
#                ROOST_AUTOCONTINUE=0 (never send the automatic "continue" prompt)

$ErrorActionPreference = 'Stop'
$CsArgs = $args
$CsHome = if ($env:ROOST_HOME) { $env:ROOST_HOME } else { Join-Path $env:LOCALAPPDATA 'roost' }
$SessDir = Join-Path $CsHome 'sessions'
$RunDir = Join-Path $CsHome 'run'
$ConfDir = Join-Path $CsHome 'config'
foreach ($d in $SessDir, $RunDir, $ConfDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$Here = $PSScriptRoot
$Self = $PSCommandPath
$Runner = Join-Path $Here 'roost-run.ps1'
$FlagsFile = Join-Path $ConfDir 'claude-flags'
$PromptFile = Join-Path $ConfDir 'resume-prompt.txt'
if (-not (Test-Path -LiteralPath $FlagsFile)) { Set-Content -LiteralPath $FlagsFile -Value '--permission-mode auto' }

# ---- look ------------------------------------------------------------------------------------------------------------
# One palette for the dashboard, `roost ls`, doctor and the psmux status bar (same colours as the Linux tmux.conf).
# No colour when the output is redirected or PowerShell renders plain text (e.g. NO_COLOR is set).
$E = [char]27
$UseColor = ($PSStyle.OutputRendering -ne 'PlainText') -and -not [Console]::IsOutputRedirected
$Dot = [string][char]0x25CF; $Ring = [string][char]0x25CB; $Pause = [string][char]0x23F8
$Ell = [string][char]0x2026; $Rule = [string][char]0x2500; $Mark = [string][char]0x203A
$Tick = [string][char]0x2713; $Cross = [string][char]0x2717; $Mid = [string][char]0x00B7
$Arrows = [string][char]0x2191 + [char]0x2193
$Accent = '38;5;39'; $Dim = '38;5;245'; $Faint = '38;5;238'; $Badge = '1;48;5;39;38;5;16'
$Green = '38;5;40'; $Red = '38;5;196'; $Yellow = '38;5;214'
# display state -> glyph (same glyphs the hook puts in the window name), label, colour (terminal SGR / psmux)
$States = [ordered]@{
    busy      = @{ Glyph = $Dot; Label = 'working'; Sgr = '38;5;214'; Mux = 'colour214' }
    attention = @{ Glyph = '?'; Label = 'decide'; Sgr = '1;38;5;201'; Mux = 'colour201' }
    waiting   = @{ Glyph = '*'; Label = 'your turn'; Sgr = '38;5;51'; Mux = 'colour51' }
    idle      = @{ Glyph = $Ring; Label = 'quiet'; Sgr = '38;5;40'; Mux = 'colour40' }
    parked    = @{ Glyph = $Pause; Label = 'parked'; Sgr = '38;5;39'; Mux = 'colour39' }
}

function Paint([string]$Text, [string]$Sgr) {
    if ($script:UseColor -and $Sgr -and $Text) { return "$E[${Sgr}m$Text$E[0m" }
    return $Text
}
function Measure-Text([string]$Text) { return ($Text -replace "$E\[[0-9;?]*[A-Za-z]", '').Length }
function Get-Width { try { $w = [Console]::WindowWidth } catch { $w = 0 }; if ($w -lt 20) { return 100 } else { return $w } }
function Get-Height { try { $h = [Console]::WindowHeight } catch { $h = 0 }; if ($h -lt 5) { return 30 } else { return $h } }
# pad / cut to exactly $Width characters; -KeepEnd cuts at the front (paths: the end is the interesting part)
function Fit([string]$Text, [int]$Width, [switch]$KeepEnd) {
    if ($Width -le 0) { return '' }
    if ($Text.Length -le $Width) { return $Text.PadRight($Width) }
    if ($Width -eq 1) { return $Ell }
    if ($KeepEnd) { return $Ell + $Text.Substring($Text.Length - $Width + 1) }
    return $Text.Substring(0, $Width - 1) + $Ell
}
function Format-Path([string]$P) {
    $h = $env:USERPROFILE
    if ($P -and $h -and $P.StartsWith($h, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $P.Substring($h.Length) }
    return $P
}
function Format-State([string]$Key, [int]$Width) {
    $s = $States[$Key]
    $t = Fit ($s.Glyph + ' ' + $s.Label) $Width
    return (Paint $t $s.Sgr)
}
function Say([string]$Msg) { Write-Host ((Paint $Mark $Accent) + ' ' + $Msg) }

function Get-Entries {
    Get-ChildItem -LiteralPath $SessDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { }
    }
}

function Test-Name([string]$Name) { return ($Name -match '^[A-Za-z0-9._-]+$') }

# A session is "open" while the window's shell (started by roost-run.ps1) is still running.
function Test-Alive([string]$Name) {
    $f = Join-Path $RunDir "$Name.run.json"
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    try {
        $r = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $p = Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue
        return [bool]($p -and ($p.StartTime.ToFileTimeUtc() -eq [int64]$r.start))
    } catch { return $false }
}

function Format-Age([long]$Sec) {
    if ($Sec -lt 60) { return "${Sec}s" }
    if ($Sec -lt 3600) { return "$([math]::Floor($Sec / 60))m" }
    if ($Sec -lt 86400) { return "$([math]::Floor($Sec / 3600))h" }
    return "$([math]::Floor($Sec / 86400))d"
}

# parked (no window) | busy | attention (? needs a decision) | waiting (* your turn) | idle
function Get-StateKey($e, [bool]$Alive) {
    if (-not $Alive) { return 'parked' }
    $d = [string]$e.display
    if ($d -in 'busy', 'attention', 'waiting') { return $d }
    return 'idle'
}

# one row per registered session, sorted by name (so the dashboard keys stay stable)
function Get-Rows {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($e in (Get-Entries | Sort-Object name)) {
        if (-not $e.name) { continue }
        $sid = [string]$e.session_id
        [pscustomobject]@{
            Name  = [string]$e.name
            State = Get-StateKey $e (Test-Alive ([string]$e.name))
            Age   = Format-Age ($now - [long]$e.updated)
            Cwd   = Format-Path ([string]$e.cwd)
            Sid   = $sid.Substring(0, [Math]::Min(8, $sid.Length))
        }
    }
}

function Get-Counts($Rows) {
    $c = [ordered]@{}
    foreach ($k in $States.Keys) { $c[$k] = 0 }
    foreach ($r in $Rows) { $c[$r.State]++ }
    return $c
}

# "● 2  ? 1  * 0  ○ 3  ⏸ 1" (zero counts dimmed)
function Format-Counts($Counts) {
    $parts = foreach ($k in $Counts.Keys) {
        $t = $States[$k].Glyph + ' ' + $Counts[$k]
        if ($Counts[$k]) { Paint $t $States[$k].Sgr } else { Paint $t $Faint }
    }
    return ($parts -join '  ')
}

function Show-List {
    $rows = @(Get-Rows)
    if (-not $rows) { Write-Output ('no sessions yet - start one with:  ' + (Paint 'roost new NAME [DIR]' $Accent)); return }
    $nw = [Math]::Min(24, [Math]::Max(4, ($rows.Name | Measure-Object -Property Length -Maximum).Maximum))
    $sw = 11
    $dw = [Math]::Max(16, (Get-Width) - 1 - (2 + $nw + 2 + $sw + 2 + 4 + 2 + 2 + 8))
    Write-Output ''
    Write-Output ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint "$($rows.Count) session(s)" $Dim) + '    ' + (Format-Counts (Get-Counts $rows)))
    Write-Output ''
    Write-Output (Paint ('  ' + (Fit 'NAME' $nw) + '  ' + (Fit 'STATE' $sw) + '  ' + (Fit 'AGE' 4) + '  ' + (Fit 'DIRECTORY' $dw) + '  SESSION') $Dim)
    foreach ($r in $rows) {
        $name = Fit $r.Name $nw
        if ($r.State -in 'attention', 'waiting') { $name = Paint $name '1' }
        Write-Output ('  ' + $name + '  ' + (Format-State $r.State $sw) + '  ' + (Paint (Fit $r.Age 4) $Dim) + '  ' + (Fit $r.Cwd $dw -KeepEnd) + '  ' + (Paint $r.Sid $Dim))
    }
    Write-Output ''
}

$PcSess = if ($env:ROOST_PSMUX_SESSION) { $env:ROOST_PSMUX_SESSION } else { 'roost' }

function Test-PcUp {
    & psmux has-session -t $PcSess 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# status bar look of the roost psmux session. Driven only by the glyph the hook puts in front of the window name
# ("● api"), because psmux has no per-window user options. Idempotent; only touches the roost session.
function Set-PcTheme {
    $first = '#{=1:window_name}'
    $bare = '#{s/^. //:window_name}'             # name without the glyph (names never contain spaces)
    $glyph = "#{?#{==:$first,$Dot},#[fg=colour214],#{?#{==:$first,?},#[fg=colour201]#[bold],#{?#{==:$first,*},#[fg=colour51],#[fg=colour244]}}}"
    $plain = "#{?#{==:$bare,#{window_name}},#W,$glyph$first#[default] $bare}"
    $current = "#{?#{==:$bare,#{window_name}},#W,$glyph$first#[fg=colour255] $bare}"
    $opts = [ordered]@{
        'mouse'                        = 'on'
        'status-interval'              = '2'
        'allow-rename'                 = 'off'
        'status-style'                 = 'bg=colour235,fg=colour250'
        'status-left'                  = '#[bg=colour39,fg=colour16,bold] roost #[default] '
        'status-left-length'           = '12'
        'status-right-length'          = '60'          # status-right itself is pushed by the dash window
        'window-status-separator'      = ''
        'window-status-format'         = " #[fg=colour244]#I#[default] $plain "
        'window-status-current-format' = "#[bg=colour238,fg=colour255,bold] #I $current #[default]"
        'pane-border-style'            = 'fg=colour238'
        'pane-active-border-style'     = 'fg=colour39'
        'message-style'                = 'bg=colour39,fg=colour16'
        'mode-style'                   = 'bg=colour39,fg=colour16'
    }
    foreach ($k in $opts.Keys) { & psmux set-option -t $PcSess $k $opts[$k] 2>$null | Out-Null }
}

# right side of the status bar: "●2 ?1 *0 ○3 ⏸1  14:02" (pushed by the dash window when the counts change)
function Format-StatusRight($Counts) {
    $parts = foreach ($k in $Counts.Keys) {
        $c = if ($Counts[$k]) { $States[$k].Mux } else { 'colour240' }
        "#[fg=$c]$($States[$k].Glyph)$($Counts[$k])"
    }
    return (($parts -join ' ') + '  #[fg=colour245]%H:%M ')
}

# creates the psmux session (detached) with the "dash" window if it does not exist yet
function Initialize-Pc {
    if (Test-PcUp) { return }
    $dashCmd = "pwsh -NoLogo -NoExit -File `"$Self`" dash"
    & psmux new-session -d -s $PcSess -n dash -c $env:USERPROFILE $dashCmd
    Set-PcTheme
}

# window id (@N) of the session's window; its name is "NAME" or "<glyph> NAME" (the hook adds the glyph)
function Get-WinId([string]$Name) {
    $rx = '^(\S\s)?' + [regex]::Escape($Name) + '$'
    foreach ($l in @(& psmux list-windows -t $PcSess -F '#{window_id}|#{window_name}' 2>$null)) {
        $p = "$l".Split('|', 2)
        if ($p.Count -eq 2 -and $p[1] -match $rx) { return $p[0] }
    }
    return $null
}

function Start-Tab([string]$Name, [string]$Cwd, [string]$Sid, [string]$Prompt, [string[]]$Extra) {
    $extraList = @($Extra | Where-Object { $_ })
    $a = [ordered]@{ sid = $Sid; prompt = $Prompt; extra = $extraList }
    [IO.File]::WriteAllText((Join-Path $RunDir "$Name.args.json"), ($a | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $dir = $Cwd.TrimEnd('\')
    $cmd = "pwsh -NoLogo -NoExit -File `"$Runner`" $Name"
    $wargs = @('new-window', '-d', '-t', "${PcSess}:", '-n', $Name, '-c', $dir, $cmd)
    if ($env:ROOST_DRY) { Write-Host ('psmux ' + ($wargs -join ' ')); return }
    Initialize-Pc
    $old = Get-WinId $Name
    if ($old) { & psmux kill-window -t $old 2>$null | Out-Null }   # stale window of a dead session
    & psmux @wargs
}

# focus a session window; from outside psmux this also attaches the terminal to the roost screen
function Switch-To([string]$Name) {
    Initialize-Pc
    $id = $null
    for ($k = 0; $k -lt 20 -and -not $id; $k++) { $id = Get-WinId $Name; if (-not $id) { Start-Sleep -Milliseconds 250 } }
    if ($id) { & psmux select-window -t $id 2>$null | Out-Null }
    if (-not $env:TMUX) { & psmux attach-session -t $PcSess }
}

# the key hints at the bottom of the dashboard, as many as fit
function Format-Keys($Items, [int]$Max) {
    $out = ' '; $len = 1
    foreach ($it in $Items) {
        $n = $it[0].Length + 1 + $it[1].Length + 3
        if ($len + $n -gt $Max) { break }
        $out += (Paint $it[0] "1;$Accent") + ' ' + (Paint $it[1] $Dim) + '   '
        $len += $n
    }
    return $out
}

# the "dash" window: lists the sessions; arrow keys + Enter or the session's key open / switch to one.
# Redraws in place (no Clear-Host flicker) and keeps the status bar counts up to date.
function Show-Dash {
    $keys = '123456789abcdefghijklmnopqrstuvwxyz'
    $hints = @(
        @($Arrows, 'select'), @('Enter', 'open'), @('1-9 a-z', 'jump'),
        @('Ctrl+B n/p', 'next / previous'), @('Ctrl+B w', 'all windows'), @('Ctrl+B d', 'detach')
    )
    $sel = $null; $top = 0; $last = ''; $lastSize = ''; $lastStatus = ''; $clear = $true
    $inMux = [bool]$env:TMUX
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    if ($inMux) { Set-PcTheme }
    [Console]::Out.Write("$E[?25l$E[?7l")   # hide the cursor, no line wrap
    try {
        while ($true) {
            $rows = @(Get-Rows | Select-Object -First $keys.Length)
            $counts = Get-Counts $rows
            if ($inMux) {
                $sr = Format-StatusRight $counts
                if ($sr -ne $lastStatus) { & psmux set-option -t $PcSess status-right $sr 2>$null | Out-Null; $lastStatus = $sr }
            }
            $ix = -1
            for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Name -eq $sel) { $ix = $i; break } }
            if ($ix -lt 0 -and $rows.Count) { $ix = 0 }
            $sel = if ($ix -ge 0) { $rows[$ix].Name } else { $null }

            $W = (Get-Width) - 1; $H = Get-Height
            $L = [System.Collections.Generic.List[string]]::new()
            $left = (Paint ' roost ' $Badge) + (Paint '  Claude Code sessions' $Dim)
            $right = (Format-Counts $counts) + '    ' + (Paint (Get-Date -Format 'HH:mm') $Dim) + ' '
            $gap = $W - (Measure-Text $left) - (Measure-Text $right)
            $L.Add($(if ($gap -ge 2) { $left + (' ' * $gap) + $right } else { $left }))
            $L.Add((Paint ($Rule * $W) $Faint))
            $L.Add('')
            if (-not $rows) {
                $L.Add('')
                $L.Add('     ' + (Paint 'No sessions yet.' '1'))
                $L.Add('')
                $L.Add('     Start one from any PowerShell window:   ' + (Paint 'roost new NAME [DIR]' $Accent))
                $L.Add('     ' + (Paint 'or press Ctrl+B c for a new window here and run it there.' $Dim))
            } else {
                $nw = [Math]::Min(24, [Math]::Max(4, ($rows.Name | Measure-Object -Property Length -Maximum).Maximum))
                $sw = 11
                $dw = [Math]::Max(0, $W - (3 + 3 + $sw + 2 + $nw + 2 + 4 + 2))
                $L.Add((Paint ('      ' + (Fit 'STATE' $sw) + '  ' + (Fit 'NAME' $nw) + '  ' + (Fit 'AGE' 4) + '  DIRECTORY') $Dim))
                $body = [Math]::Max(1, $H - 8)   # title, rule, blank, column names, "x-y of n", blank, rule, keys
                if ($ix -lt $top) { $top = $ix }
                if ($ix -ge $top + $body) { $top = $ix - $body + 1 }
                $top = [Math]::Max(0, [Math]::Min($top, $rows.Count - $body))
                $end = [Math]::Min($rows.Count, $top + $body)
                for ($i = $top; $i -lt $end; $i++) {
                    $r = $rows[$i]; $on = ($i -eq $ix)
                    $name = Fit $r.Name $nw
                    if ($on -or $r.State -in 'attention', 'waiting') { $name = Paint $name '1' }
                    $line = ' ' + $(if ($on) { Paint $Mark "1;$Accent" } else { ' ' }) + ' ' +
                        (Paint ([string]$keys[$i]) $(if ($on) { "1;$Accent" } else { $Accent })) + '  ' +
                        (Format-State $r.State $sw) + '  ' + $name + '  ' + (Paint (Fit $r.Age 4) $Dim) + '  ' + (Fit $r.Cwd $dw -KeepEnd)
                    if ($on -and $UseColor) { $bg = "$E[48;5;236m"; $line = $bg + $line.Replace("$E[0m", "$E[0m$bg") + "$E[K$E[0m" }
                    $L.Add($line)
                }
                if ($rows.Count -gt $body) { $L.Add((Paint "      $($top + 1)-$end of $($rows.Count)" $Dim)) }
            }
            while ($L.Count -lt $H - 2) { $L.Add('') }
            $L.Add((Paint ($Rule * $W) $Faint))
            $L.Add((Format-Keys $hints $W))

            $size = "${W}x$H"
            $frame = (@($L | Select-Object -First $H) -join "$E[K`r`n") + "$E[K"
            if ($clear -or $size -ne $lastSize) { [Console]::Out.Write("$E[2J"); $last = ''; $lastSize = $size; $clear = $false }
            if ($frame -ne $last) { [Console]::Out.Write("$E[H$frame$E[0m$E[J"); [Console]::Out.Flush(); $last = $frame }

            # wait up to 2 s for a key, then refresh
            $key = $null
            $sw2 = [Diagnostics.Stopwatch]::StartNew()
            while ($sw2.ElapsedMilliseconds -lt 2000) {
                if ([Console]::KeyAvailable) { $key = [Console]::ReadKey($true); break }
                Start-Sleep -Milliseconds 40
            }
            if (-not $key -or -not $rows) { continue }
            $open = $null
            switch ($key.Key) {
                ([ConsoleKey]::UpArrow) { if ($ix -gt 0) { $sel = $rows[$ix - 1].Name } }
                ([ConsoleKey]::DownArrow) { if ($ix -lt $rows.Count - 1) { $sel = $rows[$ix + 1].Name } }
                ([ConsoleKey]::Home) { $sel = $rows[0].Name }
                ([ConsoleKey]::End) { $sel = $rows[-1].Name }
                ([ConsoleKey]::Enter) { $open = $sel }
                default {
                    $k = $keys.IndexOf([char]::ToLowerInvariant($key.KeyChar))
                    if ($k -ge 0 -and $k -lt $rows.Count) { $sel = $rows[$k].Name; $open = $sel }
                }
            }
            if ($open) {
                if (-not (Test-Alive $open)) { Restore-Sessions $open $false 6>$null }
                Switch-To $open
                $clear = $true
            }
        }
    } finally {
        [Console]::Out.Write("$E[0m$E[?7h$E[?25h")
    }
}

function Wait-Network {
    $limit = if ($env:ROOST_NET_WAIT) { [int]$env:ROOST_NET_WAIT } else { 180 }
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $limit) {
        try {
            Invoke-WebRequest -Uri 'https://api.anthropic.com/' -Method Head -TimeoutSec 6 -SkipHttpErrorCheck | Out-Null
            return
        } catch { Start-Sleep -Seconds 5 }
    }
}

# crash-loop guard: 3 or more logon restores within 30 minutes => no automatic "continue" prompt
function Update-BootLog {
    $f = Join-Path $CsHome 'boots.log'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $recent = @()
    if (Test-Path -LiteralPath $f) {
        $recent = @(Get-Content -LiteralPath $f | Where-Object { $_ -match '^\d+$' -and ($now - [long]$_) -lt 1800 })
    }
    $recent += $now
    Set-Content -LiteralPath $f -Value $recent
    return ($recent.Count -ge 3)
}

function Restore-Sessions([string]$Only, [bool]$Boot) {
    $guard = $false
    if ($Boot) { Wait-Network; $guard = Update-BootLog }
    $auto = ($env:ROOST_AUTOCONTINUE -ne '0') -and (-not $guard)
    $prompt = ''
    if (Test-Path -LiteralPath $PromptFile) { $prompt = (Get-Content -LiteralPath $PromptFile -Raw -Encoding utf8).Trim() }
    $stagger = if ($env:ROOST_STAGGER) { [int]$env:ROOST_STAGGER } else { 3 }
    $n = 0
    foreach ($e in (Get-Entries | Sort-Object name)) {
        if ($Only -and $e.name -ne $Only) { continue }
        if (Test-Alive $e.name) { continue }
        $sid = ''
        if ($e.transcript -and (Test-Path -LiteralPath $e.transcript) -and ((Get-Item -LiteralPath $e.transcript).Length -gt 0)) {
            $sid = [string]$e.session_id
        }
        # only sessions that were in the middle of work get the automatic "continue" prompt
        $p = ''
        if ($auto -and $e.state -eq 'busy' -and $sid) { $p = $prompt }
        $cwd = if ($e.cwd -and (Test-Path -LiteralPath $e.cwd)) { [string]$e.cwd } else { $env:USERPROFILE }
        Start-Tab $e.name $cwd $sid $p @()
        $n++
        if (-not $Only) { Start-Sleep -Seconds $stagger }
    }
    Say "restored $n session(s)"
}

function New-Session([string[]]$A) {
    if (-not $A -or -not $A[0]) { throw 'usage: roost new NAME [DIR] [claude args, e.g. -c]' }
    $name = $A[0]
    if (-not (Test-Name $name)) { throw 'bad NAME (letters, digits, . _ -)' }
    $rest = @($A | Select-Object -Skip 1)
    $dir = $null
    if ($rest.Count -gt 0 -and -not ([string]$rest[0]).StartsWith('-')) {
        $dir = [string]$rest[0]
        $rest = @($rest | Select-Object -Skip 1)
    }
    if (-not $dir) { $dir = (Get-Location).Path }
    $dir = (Resolve-Path -LiteralPath $dir -ErrorAction Stop).Path
    if (Test-Alive $name) { Say "session '$name' is already open (roost $name switches to it)"; return }
    if ($rest.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $SessDir "$name.json"))) {
        Say "'$name' is parked - resuming it"
        Restore-Sessions $name $false
        Switch-To $name
        return
    }
    Start-Tab $name $dir '' '' $rest
    if (-not $env:ROOST_DRY) { Switch-To $name }
}

function Remove-Session([string]$Name, [bool]$Kill) {
    if (-not $Name -or -not (Test-Name $Name)) { throw 'usage: roost close|forget NAME' }
    if ($Kill -and (Test-Alive $Name)) {
        $r = Get-Content -LiteralPath (Join-Path $RunDir "$Name.run.json") -Raw | ConvertFrom-Json
        & taskkill /PID ([int]$r.pid) /T /F | Out-Null
    }
    if ($Kill) { $w = Get-WinId $Name; if ($w) { & psmux kill-window -t $w 2>$null | Out-Null } }
    Remove-Item -LiteralPath (Join-Path $SessDir "$Name.json"), (Join-Path $RunDir "$Name.run.json"), (Join-Path $RunDir "$Name.args.json") -Force -ErrorAction SilentlyContinue
    Say "removed $Name"
}

function Show-Doctor {
    function Ok([string]$k, [string]$m) { Write-Host ('  ' + (Paint $Tick $Green) + ' ' + (Fit $k 10) + ' ' + $m) }
    function Bad([string]$k, [string]$m) { Write-Host ('  ' + (Paint $Cross $Red) + ' ' + (Paint (Fit $k 10) '1') + ' ' + (Paint $m $Red)) }
    function Info([string]$k, [string]$m) { Write-Host ('  ' + (Paint $Mid $Dim) + ' ' + (Fit $k 10) + ' ' + (Paint $m $Dim)) }
    Write-Host ''
    Write-Host ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint 'doctor' $Dim))
    Write-Host ''
    foreach ($c in 'psmux', 'pwsh', 'claude', 'git') {
        $g = Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) { Ok $c (Format-Path $g.Source) } else { Bad $c 'not found in PATH' }
    }
    $sp = Join-Path $env:USERPROFILE '.claude\settings.json'
    if ((Test-Path -LiteralPath $sp) -and (Select-String -LiteralPath $sp -Pattern 'roost-hook.ps1' -SimpleMatch -Quiet)) { Ok 'hooks' 'registered in ~\.claude\settings.json' } else { Bad 'hooks' 'missing in ~\.claude\settings.json (run install.ps1)' }
    $startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'roost-restore.cmd'
    if (Test-Path -LiteralPath $startup) { Ok 'restore' 'reopens sessions at sign-in (Startup folder)' } else { Bad 'restore' 'restore-at-logon entry missing (run install.ps1)' }
    $rows = @(Get-Rows)
    $open = @($rows | Where-Object State -ne 'parked').Count
    Info 'sessions' "$($rows.Count) registered, $open open, $($rows.Count - $open) parked"
    $rdp = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($rdp -eq 0) { Info 'remote' 'Remote Desktop ON (sessions survive a dropped RDP connection)' } else { Info 'remote' 'Remote Desktop OFF (Settings > System > Remote Desktop, if you want remote access)' }
    $al = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue).AutoAdminLogon
    if ($al -eq '1') { Info 'sign-in' 'auto sign-in ON' } else { Info 'sign-in' 'auto sign-in OFF (after a power cut, sessions reopen only once you sign in)' }
    Write-Host ''
}

function Show-Help {
    $cmds = @(
        @('roost', 'open the roost screen (dashboard + one window per session)'),
        @('roost ls', 'list sessions'),
        @('roost NAME', 'open / switch to a session'),
        @('roost new NAME [DIR] [args]', 'start a session, e.g.  roost new api C:\src\api -c'),
        @('roost restore [NAME]', 'reopen parked sessions (registered, but no window)'),
        @('roost close NAME', 'close the window and forget the session'),
        @('roost forget NAME', 'forget the registry entry only'),
        @('roost doctor', 'health check'),
        @('roost selftest', 'check the scripts without opening any window')
    )
    $keyRows = @(
        @("$Arrows  Enter", 'pick a session on the dashboard (or press its key)'),
        @('Ctrl+B n / p', 'next / previous window'),
        @('Ctrl+B w', 'list all windows'),
        @('Ctrl+B d', 'detach (sessions keep running)')
    )
    Write-Host ''
    Write-Host ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint 'Claude Code sessions that keep running and come back after a reboot' $Dim))
    Write-Host ''
    Write-Host ('  ' + (Paint 'COMMANDS' '1'))
    foreach ($c in $cmds) { Write-Host ('    ' + (Paint (Fit $c[0] 30) $Accent) + $c[1]) }
    Write-Host ''
    Write-Host ('  ' + (Paint 'KEYS' '1'))
    foreach ($c in $keyRows) { Write-Host ('    ' + (Paint (Fit $c[0] 30) $Accent) + $c[1]) }
    Write-Host ''
    Write-Host ('  ' + (Paint 'STATES' '1'))
    $legend = foreach ($k in $States.Keys) { (Paint $States[$k].Glyph $States[$k].Sgr) + ' ' + $States[$k].Label }
    Write-Host ('    ' + ($legend -join '    '))
    Write-Host ''
}

function Invoke-SelfTest {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('roost-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $saved = @{ H = $env:ROOST_HOME; N = $env:ROOST_NAME; D = $env:ROOST_DRY }
    $env:ROOST_HOME = $tmp; $env:ROOST_NAME = 'selftest'; $env:ROOST_DRY = '1'
    $script:fails = 0; $script:checks = 0
    $hook = Join-Path $Here 'roost-hook.ps1'
    $reg = Join-Path $tmp 'sessions\selftest.json'
    $check = {
        param($label, $cond)
        $script:checks++
        if ($cond) { Write-Host ('  ' + (Paint $Tick $Green) + ' ' + $label) }
        else { Write-Host ('  ' + (Paint $Cross $Red) + ' ' + (Paint $label $Red)); $script:fails++ }
    }
    $call = { param($ev, $json) $json | & pwsh -NoProfile -File $hook $ev }
    $read = { Get-Content -LiteralPath $reg -Raw | ConvertFrom-Json }
    Write-Host ''
    Write-Host ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint 'selftest' $Dim))
    Write-Host ''
    try {
        $j0 = @{ session_id = 'sid-1'; cwd = $tmp; transcript_path = 'x' } | ConvertTo-Json -Compress
        $o = & $call 'start' $j0
        & $check 'hook is silent on stdout' (-not $o)
        & $check 'start registers the session' (Test-Path -LiteralPath $reg)
        $r = & $read; & $check 'start -> idle' (($r.state -eq 'idle') -and ($r.display -eq 'idle'))
        & $call 'busy' $j0 | Out-Null
        $r = & $read; & $check 'busy' (($r.state -eq 'busy') -and ($r.display -eq 'busy'))
        & $call 'attention' '{"session_id":"sid-1","notification_type":"permission_prompt"}' | Out-Null
        $r = & $read; & $check 'permission prompt -> ? (state stays busy)' (($r.display -eq 'attention') -and ($r.state -eq 'busy'))
        & $call 'idle' $j0 | Out-Null
        $r = & $read; & $check 'stop -> * waiting, state idle' (($r.display -eq 'waiting') -and ($r.state -eq 'idle'))
        & $call 'end' '{"reason":"other"}' | Out-Null
        & $check 'end(other) keeps the entry' (Test-Path -LiteralPath $reg)
        & $call 'end' '{"reason":"prompt_input_exit"}' | Out-Null
        & $check '/exit forgets the entry' (-not (Test-Path -LiteralPath $reg))
        $out = (& pwsh -NoProfile -File $Self new selftab $tmp -c | Out-String)
        & $check 'new prints a psmux command (dry run)' ($out -match 'new-window.* -n selftab')
        $af = Join-Path $tmp 'run\selftab.args.json'
        & $check 'extra args are passed on (-c)' ((Test-Path -LiteralPath $af) -and ((Get-Content -LiteralPath $af -Raw) -match '"-c"'))
        & $check 'psmux is installed' ([bool](Get-Command psmux -ErrorAction SilentlyContinue))
        & $check 'claude is installed' ([bool](Get-Command claude -ErrorAction SilentlyContinue))
    } finally {
        $env:ROOST_HOME = $saved.H; $env:ROOST_NAME = $saved.N; $env:ROOST_DRY = $saved.D
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    if ($script:fails) { Write-Host ('  ' + (Paint "selftest: $($script:fails) of $($script:checks) check(s) FAILED" "1;$Red")) }
    else { Write-Host ('  ' + (Paint "selftest: all $($script:checks) checks passed" $Green)) }
    Write-Host ''
}

try {
    $cmd = if ($CsArgs.Count) { [string]$CsArgs[0] } else { 'screen' }
    $rest = @($CsArgs | Select-Object -Skip 1)
    switch ($cmd) {
        'screen' {
            Initialize-Pc
            $d = Get-WinId 'dash'
            if ($d) { & psmux select-window -t $d 2>$null | Out-Null }
            if (-not $env:TMUX) { & psmux attach-session -t $PcSess }
        }
        'dash' { Show-Dash }
        { $_ -in 'ls', 'list', 'l' } { Show-List }
        { $_ -in 'new', 'n' } { New-Session $rest }
        { $_ -in 'restore', 'r' } {
            $boot = (($rest -contains '-Boot') -or ($rest -contains '--boot'))
            $only = $rest | Where-Object { $_ -notmatch '^--?[Bb]oot$' } | Select-Object -First 1
            Restore-Sessions ([string]$only) $boot
        }
        'close' { Remove-Session ([string]$rest[0]) $true }
        'forget' { Remove-Session ([string]$rest[0]) $false }
        'doctor' { Show-Doctor }
        'selftest' { Invoke-SelfTest }
        { $_ -in 'help', '-h', '--help' } { Show-Help }
        default {
            # `roost NAME`: open a parked session (like Linux `roost NAME`)
            if ((Test-Name $cmd) -and (Test-Path -LiteralPath (Join-Path $SessDir "$cmd.json"))) {
                if (-not (Test-Alive $cmd)) { Restore-Sessions $cmd $false }
                Switch-To $cmd
            } else { throw "unknown command '$cmd' (roost help)" }
        }
    }
} catch {
    Write-Host ((Paint 'roost:' "1;$Red") + ' ' + (Paint $_.Exception.Message $Red))
    exit 1
}
