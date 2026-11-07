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
#                ROOST_AUTOCONTINUE=0 (never send the automatic "continue" prompt), ROOST_PSMUX_SESSION (default roost),
#                ROOST_MOUSE=0 (dashboard ignores the mouse)

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
$Bird = [char]::ConvertFromUtf32(0x1F426)   # terminal tab title and the Windows Terminal profile icon
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
function Format-Rc([string]$Rc, [int]$Width) {
    switch ($Rc) {
        'on' { return (Paint (Fit 'on' $Width) $Green) }
        'off' { return (Paint (Fit 'off' $Width) $Dim) }
        default { return (Fit '' $Width) }
    }
}

# ---- Remote Control ---------------------------------------------------------------------------------------------------
# Claude Code keeps one file per running process in ~/.claude/sessions/<pid>.json (CLAUDE_CONFIG_DIR moves ~/.claude);
# bridgeSessionId is set while that process is connected to Remote Control. This is Claude Code's internal, undocumented
# format, so everything here fails soft: no file, a dead or reused pid, or a missing field just shows no RC state.
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

# session id -> 'on' | 'off', for every live claude process
function Get-RcIndex {
    $procs = @(Get-ChildItem -LiteralPath (Join-Path $ClaudeDir 'sessions') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                $p = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
                if ($j.sessionId -and $p -and $p.StartTime.ToFileTimeUtc() -eq [int64]$j.procStart) { $j }
            } catch { }
        })
    $idx = @{}
    foreach ($j in $procs) { $idx[[string]$j.sessionId] = $(if ($j.bridgeSessionId) { 'on' } else { 'off' }) }
    # a session handed over to a background job (parkedJobId -> jobId) keeps its Remote Control in the job's process
    foreach ($j in $procs) {
        if (-not $j.parkedJobId) { continue }
        $job = @($procs | Where-Object { $_.jobId -eq $j.parkedJobId }) | Select-Object -First 1
        if ($job) { $idx[[string]$j.sessionId] = $(if ($job.bridgeSessionId) { 'on' } else { 'off' }) }
    }
    return $idx
}

# ---- dashboard input: keys and mouse ----------------------------------------------------------------------------------
# The dash reads console input records itself: [Console]::KeyAvailable silently drops mouse records. It asks for the
# mouse (ENABLE_MOUSE_INPUT here, DECSET 1000/1006 in Show-Dash); psmux then forwards clicks in the dash pane only.
# Other windows keep psmux's own mouse handling (no global bindings).
# psmux types what the attached terminal sends into the pane as VT TEXT: key-down records with vk 0 carrying
# "ESC [ A" for Up or "ESC [ < 0 ; 11 ; 6 M" for a click (only the key-up records carry the real vk). So the reader parses
# escape sequences itself, and nothing inside one may count as a key: the digits of a click's coordinates would
# otherwise "press" 1-9 and open sessions. Real MOUSE_EVENT records (e.g. from `send-keys -l`) are handled too.
# ROOST_DASH_LOG=<file> logs every raw input record.
$DashInputSrc = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public sealed class RoostDashEvent { public int Vk; public char Ch; public bool Click; public int Y = -1; public int Wheel; }
public static class RoostDashInput {
    [StructLayout(LayoutKind.Explicit)] struct KEY { [FieldOffset(0)] public int Down; [FieldOffset(4)] public ushort Repeat; [FieldOffset(6)] public ushort Vk; [FieldOffset(8)] public ushort Scan; [FieldOffset(10)] public ushort Ch; [FieldOffset(12)] public uint Ctrl; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSE { public short X; public short Y; public uint Buttons; public uint Ctrl; public uint Flags; }
    [StructLayout(LayoutKind.Explicit)] struct REC { [FieldOffset(0)] public ushort Type; [FieldOffset(4)] public KEY Key; [FieldOffset(4)] public MOUSE Mouse; }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", EntryPoint = "ReadConsoleInputW")] static extern bool ReadConsoleInput(IntPtr h, [Out] REC[] b, uint n, out uint read);
    static IntPtr h; static uint saved; static bool on;
    public static string LogPath;

    // VT input off; with mouse: mouse records on and quick edit (mouse selects text) off
    public static bool Enable(bool mouse) {
        h = GetStdHandle(-10);
        if (!GetConsoleMode(h, out saved)) return false;
        uint m = saved & ~0x0200u;
        if (mouse) m = (m | 0x0010u | 0x0080u) & ~0x0040u;
        on = SetConsoleMode(h, m);
        return on;
    }
    public static void Restore() { if (on) { SetConsoleMode(h, saved); on = false; } }

    static bool ReadRec(long ms, out REC rec) {
        rec = default(REC);
        if (WaitForSingleObject(h, (uint)Math.Max(0, ms)) != 0) return false;
        var buf = new REC[1]; uint n;
        if (!ReadConsoleInput(h, buf, 1, out n) || n == 0) return false;
        rec = buf[0];
        if (LogPath != null) {
            string d = rec.Type == 1 ? "key down=" + rec.Key.Down + " vk=" + rec.Key.Vk + " ch=" + rec.Key.Ch
                     : rec.Type == 2 ? "mouse x=" + rec.Mouse.X + " y=" + rec.Mouse.Y + " b=" + rec.Mouse.Buttons.ToString("x") + " f=" + rec.Mouse.Flags
                     : "type=" + rec.Type;
            try { File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss.fff ") + d + "\n"); } catch { }
        }
        return true;
    }

    // the next character of an escape sequence (key-down records only), or -1 after ms without one
    static int SeqChar(int ms) {
        long until = Environment.TickCount64 + ms;
        while (true) {
            long left = until - Environment.TickCount64;
            if (left <= 0) return -1;
            REC r;
            if (!ReadRec(left, out r)) return -1;
            if (r.Type == 1 && r.Key.Down != 0 && r.Key.Ch != 0) return r.Key.Ch;
        }
    }

    static RoostDashEvent Key(int vk) { return new RoostDashEvent { Vk = vk }; }
    static RoostDashEvent Cursor(int f) {
        switch (f) { case 'A': return Key(38); case 'B': return Key(40); case 'H': return Key(36); case 'F': return Key(35); }
        return null;
    }

    // after ESC: "[" params final (CSI) or "O" final (SS3); anything else is a lone Esc / Alt+key and is ignored
    static RoostDashEvent Escape() {
        int c = SeqChar(250);
        if (c == 'O') return Cursor(SeqChar(1000));
        if (c != '[') return null;
        var p = new StringBuilder();
        while (true) {
            int x = SeqChar(1000);
            if (x < 0 || p.Length > 32) return null;
            if (x >= 0x40 && x <= 0x7E) return Csi(p.ToString(), x);
            p.Append((char)x);
        }
    }

    static RoostDashEvent Csi(string p, int f) {
        if (p.StartsWith("<") && (f == 'M' || f == 'm')) {          // SGR mouse: ESC [ < button ; x ; y M (press) / m (release)
            var a = p.Substring(1).Split(';');
            int b, x, y;
            if (a.Length != 3 || !int.TryParse(a[0], out b) || !int.TryParse(a[1], out x) || !int.TryParse(a[2], out y)) return null;
            if ((b & 64) != 0) return f == 'M' ? new RoostDashEvent { Wheel = (b & 1) == 0 ? 1 : -1 } : null;
            if (f == 'M' && (b & 32) == 0 && (b & 3) == 0) return new RoostDashEvent { Click = true, Y = y - 1 };
            return null;                                              // release, motion, middle / right button
        }
        if (f == '~') { if (p == "1" || p == "7") return Key(36); if (p == "4" || p == "8") return Key(35); return null; }
        return Cursor(f);
    }

    // the next key press, left click or wheel step within ms milliseconds (other records are dropped), else null
    public static RoostDashEvent Next(int ms) {
        long until = Environment.TickCount64 + ms;
        while (true) {
            long left = Math.Max(0, until - Environment.TickCount64);
            REC r;
            if (!ReadRec(left, out r)) return null;
            RoostDashEvent ev = null;
            if (r.Type == 1 && r.Key.Down != 0) {
                int ch = r.Key.Ch;
                if (ch == 27) ev = Escape();
                else if (ch == 13) ev = Key(13);
                else if (ch >= 32) ev = new RoostDashEvent { Ch = (char)ch };
                else if (ch == 0 && r.Key.Vk != 0) ev = Key(r.Key.Vk);   // a plain console key without a character (arrows)
            } else if (r.Type == 2) {
                var m = r.Mouse;
                if ((m.Flags & 0x4) != 0) ev = new RoostDashEvent { Wheel = ((short)(m.Buttons >> 16)) > 0 ? 1 : -1 };
                else if (m.Flags == 0 && (m.Buttons & 0x1) != 0) ev = new RoostDashEvent { Click = true, Y = m.Y };
            }
            if (ev != null) return ev;
            if (left == 0) return null;
        }
    }
}
'@

# $true when the record reader is active (keys always go through it; the mouse only when $Mouse)
function Enable-DashInput([bool]$Mouse) {
    try {
        if (-not ('RoostDashInput' -as [type])) { Add-Type -TypeDefinition $DashInputSrc }
        if ($env:ROOST_DASH_LOG) { [RoostDashInput]::LogPath = $env:ROOST_DASH_LOG }
        return [RoostDashInput]::Enable($Mouse)
    } catch { return $false }
}

# waits up to $Ms ms for a key, click or wheel step: @{ Vk; Ch; Click; Y (screen line); Wheel (+1 up / -1 down) } or $null
function Read-DashInput([int]$Ms, [bool]$Reader) {
    if ($Reader) {
        $ev = [RoostDashInput]::Next($Ms)
        if (-not $ev) { return $null }
        $y = $ev.Y
        if ($ev.Click) { try { $y -= [Console]::WindowTop } catch { } }
        return [pscustomobject]@{ Vk = $ev.Vk; Ch = $ev.Ch; Click = $ev.Click; Y = $y; Wheel = $ev.Wheel }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            return [pscustomobject]@{ Vk = [int]$k.Key; Ch = $k.KeyChar; Click = $false; Y = -1; Wheel = 0 }
        }
        Start-Sleep -Milliseconds 40
    }
    return $null
}

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
    $rc = Get-RcIndex
    foreach ($e in (Get-Entries | Sort-Object name)) {
        if (-not $e.name) { continue }
        $sid = [string]$e.session_id
        $alive = Test-Alive ([string]$e.name)
        [pscustomobject]@{
            Name  = [string]$e.name
            State = Get-StateKey $e $alive
            Age   = Format-Age ($now - [long]$e.updated)
            Rc    = $(if ($alive -and $sid -and $rc.ContainsKey($sid)) { $rc[$sid] } else { '' })
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
    $dw = [Math]::Max(16, (Get-Width) - 1 - (2 + $nw + 2 + $sw + 2 + 4 + 2 + 3 + 2 + 2 + 8))
    Write-Output ''
    Write-Output ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint "$($rows.Count) session(s)" $Dim) + '    ' + (Format-Counts (Get-Counts $rows)))
    Write-Output ''
    Write-Output (Paint ('  ' + (Fit 'NAME' $nw) + '  ' + (Fit 'STATE' $sw) + '  ' + (Fit 'AGE' 4) + '  ' + (Fit 'RC' 3) + '  ' + (Fit 'DIRECTORY' $dw) + '  SESSION') $Dim)
    foreach ($r in $rows) {
        $name = Fit $r.Name $nw
        if ($r.State -in 'attention', 'waiting') { $name = Paint $name '1' }
        Write-Output ('  ' + $name + '  ' + (Format-State $r.State $sw) + '  ' + (Paint (Fit $r.Age 4) $Dim) + '  ' + (Format-Rc $r.Rc 3) + '  ' + (Fit $r.Cwd $dw -KeepEnd) + '  ' + (Paint $r.Sid $Dim))
    }
    Write-Output ''
}

$PcSess = if ($env:ROOST_PSMUX_SESSION) { $env:ROOST_PSMUX_SESSION } else { 'roost' }

function Test-PcUp {
    & psmux has-session -t $PcSess 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# status bar look of the roost psmux session, the same as the Linux tmux.conf: it lists only the dash window, the
# current window and the sessions that want something, as "3:api ●" (● working, ? decide, * your turn); quiet sessions
# are hidden, the current window is reversed. psmux has no per-window user options, so the state is the glyph in front
# of the window name ("● api"), put there by the hook and kept in step by the dash window (Sync-WinNames).
# Idempotent; only touches the roost session.
function Set-PcTheme {
    $first = '#{=1:window_name}'
    $bare = "#{s/^[${Dot}?*${Ring}] //:window_name}"   # name without the glyph (session names never contain these)
    $busy = "#{==:$first,$Dot}"; $ask = "#{==:$first,?}"; $wait = "#{==:$first,*}"; $idle = "#{==:$first,$Ring}"
    $shown = "#{||:#{==:#{window_name},dash},#{||:$busy,#{||:$ask,$wait}}}"
    $mark = "#{?$busy,#[fg=colour214] $Dot,#{?$ask,#[fg=colour201]#[bold] ?,#{?$wait,#[fg=colour51] *,}}}"
    $markCur = "#{?$busy, $Dot,#{?$ask, ?,#{?$wait, *,#{?$idle, $Ring,}}}}"
    $opts = [ordered]@{
        'mouse'                        = 'on'
        'status-interval'              = '2'
        'allow-rename'                 = 'off'
        'status-style'                 = 'bg=colour235,fg=colour250'
        'status-left'                  = ' roost '
        'status-left-length'           = '8'
        'status-right-length'          = '60'          # status-right itself is pushed by the dash window
        'window-status-separator'      = ''
        'window-status-format'         = "#{?$shown, #I:$bare$mark#[default] ,}"
        'window-status-current-format' = "#[reverse]#[bold] #I:$bare$markCur #[default]"
        'pane-border-style'            = 'fg=colour238'
        'pane-active-border-style'     = 'fg=colour39'
        'message-style'                = 'bg=colour39,fg=colour16'
        'mode-style'                   = 'bg=colour39,fg=colour16'
        'set-titles'                   = 'on'          # the terminal tab says roost (the dash window adds the counts)
        'set-titles-string'            = "$Bird roost"
    }
    foreach ($k in $opts.Keys) { & psmux set-option -t $PcSess $k $opts[$k] 2>$null | Out-Null }
}

# terminal tab title: "🐦 roost", plus the sessions that wait for you: "🐦 roost  ?1 *2"
function Format-Title($Counts) {
    $t = "$Bird roost"
    $wait = @(foreach ($k in 'attention', 'waiting') { if ($Counts[$k]) { $States[$k].Glyph + $Counts[$k] } })
    if ($wait) { $t += '  ' + ($wait -join ' ') }
    return $t
}

# attach this terminal to the roost screen; after a detach the tab gets its old title back
function Invoke-Attach {
    $old = $null
    try { $old = [Console]::Title } catch { }
    & psmux attach-session -t $PcSess
    if ($old) { try { [Console]::Title = $old } catch { } }
}

# right side of the status bar: "●2 ?1 *0 ○3 ⏸1 C:61%  14:02", disk in red from 90% (pushed by the dash window when it
# changes; "%%" because psmux runs the status line through strftime)
function Format-StatusRight($Counts) {
    $parts = foreach ($k in $Counts.Keys) {
        $c = if ($Counts[$k]) { $States[$k].Mux } else { 'colour240' }
        "#[fg=$c]$($States[$k].Glyph)$($Counts[$k])"
    }
    $disk = ''
    try {
        $dv = [IO.DriveInfo]::new($env:SystemDrive)
        $pct = [int][Math]::Round(100 * (1 - $dv.AvailableFreeSpace / $dv.TotalSize))
        $dc = if ($pct -ge 90) { 'colour196,bold' } else { 'colour245' }
        $disk = " #[fg=$dc]$($env:SystemDrive)$pct%%"
    } catch { }
    return (($parts -join ' ') + $disk + '  #[fg=colour245]%H:%M ')
}

# keeps the glyph in front of each open session's window name in step with the registry. The hook renames at once
# when it can; a session moved to a background job runs its hooks outside psmux and cannot.
function Sync-WinNames($Rows) {
    $want = @{}
    foreach ($r in $Rows) { if ($r.State -ne 'parked') { $want[$r.Name] = $States[$r.State].Glyph + ' ' + $r.Name } }
    if (-not $want.Count) { return }
    foreach ($l in @(& psmux list-windows -t $PcSess -F '#{window_id}|#{window_name}' 2>$null)) {
        $p = "$l".Split('|', 2)
        if ($p.Count -ne 2) { continue }
        $bare = $p[1] -replace '^\S\s', ''
        if ($want.ContainsKey($bare) -and $p[1] -cne $want[$bare]) {
            & psmux rename-window -t "${PcSess}:$($p[0])" $want[$bare] 2>$null | Out-Null
        }
    }
}

# creates the psmux session (detached) with the "dash" window if it does not exist yet
function Initialize-Pc {
    if (Test-PcUp) { return }
    $dashCmd = "pwsh -NoLogo -NoExit -File `"$Self`" dash"
    & psmux new-session -d -s $PcSess -n dash -c $env:USERPROFILE $dashCmd
    Set-PcTheme
}

# target ("roost:@N") of the session's window; its name is "NAME" or "<glyph> NAME" (the hook adds the glyph).
# Always session-qualified: psmux window ids are per session, so a bare @N can hit a window of another psmux session.
function Get-WinId([string]$Name) {
    $rx = '^(\S\s)?' + [regex]::Escape($Name) + '$'
    foreach ($l in @(& psmux list-windows -t $PcSess -F '#{window_id}|#{window_name}' 2>$null)) {
        $p = "$l".Split('|', 2)
        if ($p.Count -eq 2 -and $p[1] -match $rx) { return "${PcSess}:$($p[0])" }
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
    if (-not $env:TMUX) { Invoke-Attach }
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

# the "dash" window: lists the sessions; arrow keys + Enter, the session's key or a click open / switch to one.
# Redraws in place (no Clear-Host flicker) and keeps the status bar counts and the tab title up to date.
$RowY0 = 4   # screen line of the first session row (after the title, the rule, a blank line and the column names)
function Show-Dash {
    $keys = '123456789abcdefghijklmnopqrstuvwxyz'
    $sel = $null; $top = 0; $end = 0; $last = ''; $lastSize = ''; $lastStatus = ''; $lastTitle = ''; $clear = $true
    $inMux = [bool]$env:TMUX
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    if ($inMux) { Set-PcTheme }
    $wantMouse = ($env:ROOST_MOUSE -ne '0')
    $reader = Enable-DashInput $wantMouse
    $mouse = $reader -and $wantMouse
    $hints = @(
        @($Arrows, 'select'), @($(if ($mouse) { 'Enter/click' } else { 'Enter' }), 'open'), @('1-9 a-z', 'jump'),
        @('Ctrl+B n/p', 'next / previous'), @('Ctrl+B w', 'all windows'), @('Ctrl+B d', 'detach')
    )
    [Console]::Out.Write("$E[?25l$E[?7l")   # hide the cursor, no line wrap
    if ($mouse) { [Console]::Out.Write("$E[?1000h$E[?1006h") }   # ask for clicks: psmux forwards them to this pane only
    try {
        while ($true) {
            $rows = @(Get-Rows | Select-Object -First $keys.Length)
            $counts = Get-Counts $rows
            if ($inMux) {
                $sr = Format-StatusRight $counts
                if ($sr -ne $lastStatus) { & psmux set-option -t $PcSess status-right $sr 2>$null | Out-Null; $lastStatus = $sr }
                $tt = Format-Title $counts
                if ($tt -ne $lastTitle) { & psmux set-option -t $PcSess set-titles-string $tt 2>$null | Out-Null; $lastTitle = $tt }
                Sync-WinNames $rows
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
                $dw = [Math]::Max(0, $W - (3 + 3 + $sw + 2 + $nw + 2 + 4 + 2 + 3 + 2))
                $L.Add((Paint ('      ' + (Fit 'STATE' $sw) + '  ' + (Fit 'NAME' $nw) + '  ' + (Fit 'AGE' 4) + '  ' + (Fit 'RC' 3) + '  DIRECTORY') $Dim))
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
                        (Format-State $r.State $sw) + '  ' + $name + '  ' + (Paint (Fit $r.Age 4) $Dim) + '  ' + (Format-Rc $r.Rc 3) + '  ' + (Fit $r.Cwd $dw -KeepEnd)
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

            # wait up to 2 s for a key, a click or the wheel, then refresh
            $in = Read-DashInput 2000 $reader
            if (-not $in -or -not $rows) { continue }
            $open = $null
            if ($in.Wheel -gt 0) { if ($ix -gt 0) { $sel = $rows[$ix - 1].Name } }
            elseif ($in.Wheel -lt 0) { if ($ix -lt $rows.Count - 1) { $sel = $rows[$ix + 1].Name } }
            elseif ($in.Click) {
                # only the session rows react; $top / $end are the rows drawn in this frame
                $i = $top + ($in.Y - $RowY0)
                if ($in.Y -ge $RowY0 -and $i -lt $end) { $sel = $rows[$i].Name; $open = $sel }
            } else {
                switch ($in.Vk) {
                    ([int][ConsoleKey]::UpArrow) { if ($ix -gt 0) { $sel = $rows[$ix - 1].Name } }
                    ([int][ConsoleKey]::DownArrow) { if ($ix -lt $rows.Count - 1) { $sel = $rows[$ix + 1].Name } }
                    ([int][ConsoleKey]::Home) { $sel = $rows[0].Name }
                    ([int][ConsoleKey]::End) { $sel = $rows[-1].Name }
                    ([int][ConsoleKey]::Enter) { $open = $sel }
                    default {
                        $k = $keys.IndexOf([char]::ToLowerInvariant($in.Ch))
                        if ($k -ge 0 -and $k -lt $rows.Count) { $sel = $rows[$k].Name; $open = $sel }
                    }
                }
            }
            if ($open) {
                if (-not (Test-Alive $open)) { Restore-Sessions $open $false 6>$null }
                Switch-To $open
                $clear = $true
            }
        }
    } finally {
        if ($mouse) { [Console]::Out.Write("$E[?1006l$E[?1000l") }
        if ($reader) { [RoostDashInput]::Restore() }
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
    Info 'rc' "$(@($rows | Where-Object Rc -eq 'on').Count) of $open open session(s) connected to Remote Control"
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
        @("$Arrows  Enter  click", 'pick a session on the dashboard (or press its key)'),
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
    $saved = @{ H = $env:ROOST_HOME; N = $env:ROOST_NAME; D = $env:ROOST_DRY; C = $script:ClaudeDir }
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
        $compiled = try { if (-not ('RoostDashInput' -as [type])) { Add-Type -TypeDefinition $DashInputSrc }; $true } catch { $false }
        & $check 'dashboard mouse input compiles' $compiled
        # Remote Control state from Claude Code's per-process files (fake ones for this process, plus a stale one)
        $cs = Join-Path $tmp 'claude\sessions'
        New-Item -ItemType Directory -Force -Path $cs | Out-Null
        $st = (Get-Process -Id $PID).StartTime.ToFileTimeUtc()
        @{ pid = $PID; procStart = $st; sessionId = 'sid-on'; bridgeSessionId = 'session_x' } | ConvertTo-Json | Set-Content (Join-Path $cs 'a.json')
        @{ pid = $PID; procStart = $st; sessionId = 'sid-off'; bridgeSessionId = '' } | ConvertTo-Json | Set-Content (Join-Path $cs 'b.json')
        @{ pid = $PID; procStart = 1; sessionId = 'sid-stale'; bridgeSessionId = 'session_y' } | ConvertTo-Json | Set-Content (Join-Path $cs 'c.json')
        $script:ClaudeDir = Join-Path $tmp 'claude'
        $rc = Get-RcIndex
        & $check 'Remote Control: on / off / stale pid ignored' (($rc['sid-on'] -eq 'on') -and ($rc['sid-off'] -eq 'off') -and -not $rc.ContainsKey('sid-stale'))
        & $check 'psmux is installed' ([bool](Get-Command psmux -ErrorAction SilentlyContinue))
        & $check 'claude is installed' ([bool](Get-Command claude -ErrorAction SilentlyContinue))
    } finally {
        $env:ROOST_HOME = $saved.H; $env:ROOST_NAME = $saved.N; $env:ROOST_DRY = $saved.D; $script:ClaudeDir = $saved.C
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
            if (-not $env:TMUX) { Invoke-Attach }
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
