#requires -Version 7
# roost - Claude Code sessions on Windows. Every session is a window of ONE psmux (tmux for Windows) session "roost":
# sessions keep running when you close the terminal / drop SSH, and a small registry lets them be reopened with
# --resume after a reboot / logon.
#
#   roost                                open the roost screen (psmux session "roost"; window "dash" lists the sessions)
#   roost ls                             list sessions
#   roost NAME                           open / switch to a session
#   roost new NAME [DIR] [claude args]   open a session window, e.g.  roost new api C:\src\api -c
#                                        DIR defaults to $ROOST_PROJECT_ROOT\NAME (default ~\NAME) if it exists, else here;
#                                        --connectors keeps claude.ai connectors on for this session
#   roost restore [NAME]                 reopen parked sessions (no window) and exited ones (claude quit in its window)
#   roost close NAME                     /exit the session, close its window and forget it
#   roost forget NAME                    forget the registry entry only
#   roost next                           jump to the next session that waits for you (? first, then *); psmux: Ctrl+B a
#   roost doctor                         health check
#   roost selftest                       check the scripts without opening any window
#
# Registry: %LOCALAPPDATA%\roost\sessions\NAME.json, written by roost-hook.ps1 through Claude Code hooks.
# Only /exit or /logout forgets a session; closing the window or rebooting keeps it for `roost restore`.
# Config (%LOCALAPPDATA%\roost\config): claude-flags, resume-prompt.txt, connectors-allow (sessions, or *, that keep
# claude.ai connectors on; others start with ENABLE_CLAUDEAI_MCP_SERVERS=false).
# Env overrides: ROOST_HOME, ROOST_DRY=1 (print the psmux command instead of running it), ROOST_STAGGER (s), ROOST_NET_WAIT (s),
#                ROOST_AUTOCONTINUE=0 (never send the automatic "continue" prompt), ROOST_PSMUX_SESSION (default roost),
#                ROOST_MOUSE=0 (dashboard ignores the mouse), ROOST_CLAUDE_BIN, ROOST_PROJECT_ROOT

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
$ConnFile = Join-Path $ConfDir 'connectors-allow'
if (-not (Test-Path -LiteralPath $FlagsFile)) { Set-Content -LiteralPath $FlagsFile -Value '--permission-mode auto' }
if (-not (Test-Path -LiteralPath $ConnFile)) { Set-Content -LiteralPath $ConnFile -Value '*' }

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
    shell     = @{ Glyph = $Cross; Label = 'exited'; Sgr = '38;5;196'; Mux = 'colour196' }   # claude quit, the window stayed (Linux: SHELL)
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

# ---- model / effort / advisor -----------------------------------------------------------------------------------------
# Hooks don't carry these (model only on some SessionStarts, the advisor nowhere), but every assistant entry of the
# session's transcript does: message.model, effort and advisorModel, including /model, /effort and /advisor changes.
# Internal, undocumented format: read only the end of the file, skip subagent (isSidechain) entries, fail soft, and
# cache per transcript until the file changes.
$InfoCache = @{}
$NoInfo = [pscustomobject]@{ Model = ''; Effort = ''; Advisor = '' }

# "claude-opus-5-5" -> "opus 5.5", "claude-3-5-sonnet-20241022" -> "sonnet 3.5"; anything else as it is
function Format-Model([string]$Id) {
    $m = ($Id -replace '^claude-', '' -replace '-\d{8}$', '' -replace '\[[^\]]*\]$', '').ToLowerInvariant()
    if ($m -match '^([a-z]+)-(\d+)-(\d+)$') { return "$($matches[1]) $($matches[2]).$($matches[3])" }
    if ($m -match '^([a-z]+)-(\d+)$') { return "$($matches[1]) $($matches[2])" }
    if ($m -match '^(\d+)-(\d+)-([a-z]+)$') { return "$($matches[3]) $($matches[1]).$($matches[2])" }
    return $m
}

# the last main-thread assistant entry within the last $Tail bytes of a transcript, parsed, or $null
function Read-LastAssistant([string]$Path, [long]$Tail) {
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $start = [Math]::Max(0, $fs.Length - $Tail)
        $buf = [byte[]]::new($fs.Length - $start)
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $n = 0; while ($n -lt $buf.Length) { $r = $fs.Read($buf, $n, $buf.Length - $n); if ($r -le 0) { break }; $n += $r }
    } finally { $fs.Dispose() }
    $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $n).Split("`n")
    $first = if ($start -gt 0) { 1 } else { 0 }   # the first line of a tail read is cut off
    for ($i = $lines.Count - 1; $i -ge $first; $i--) {
        $l = $lines[$i]
        if (-not $l.Contains('"type":"assistant"')) { continue }
        try { $j = $l | ConvertFrom-Json -Depth 100 } catch { continue }
        if ($j.type -eq 'assistant' -and -not $j.isSidechain -and $j.message.model) { return $j }
    }
    return $null
}

# a small JSON file, parsed, cached until it changes; $null when missing or unreadable
$JsonCache = @{}
function Read-JsonCached([string]$Path) {
    try { $fi = [IO.FileInfo]::new($Path) } catch { return $null }
    if (-not $fi.Exists) { return $null }
    $key = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    $c = $script:JsonCache[$Path]
    if ($c -and $c.Key -eq $key) { return $c.Obj }
    $o = try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $null }
    $script:JsonCache[$Path] = @{ Key = $key; Obj = $o }
    return $o
}

# what a session that has not answered yet is configured to use (shown dim): the cwd's .claude\settings.local.json,
# then .claude\settings.json, then the user's settings (model, effortLevel, advisorModel), overridden by the --model /
# --effort / --advisor it was launched with (run\NAME.args.json)
function Get-ConfiguredInfo([string]$Name, [string]$Cwd) {
    $v = @{ model = ''; effortLevel = ''; advisorModel = '' }
    $files = @()
    if ($Cwd) { $files += (Join-Path $Cwd '.claude\settings.local.json'), (Join-Path $Cwd '.claude\settings.json') }
    $files += (Join-Path $ClaudeDir 'settings.json')
    foreach ($f in $files) {
        $j = Read-JsonCached $f
        if (-not $j) { continue }
        foreach ($k in @($v.Keys)) { if (-not $v[$k] -and $j.$k) { $v[$k] = [string]$j.$k } }
    }
    $a = Read-JsonCached (Join-Path $RunDir "$Name.args.json")
    $x = @(if ($a) { $a.extra })
    for ($i = 0; $i -lt $x.Count - 1; $i++) {
        switch ($x[$i]) { '--model' { $v.model = [string]$x[$i + 1] } '--effort' { $v.effortLevel = [string]$x[$i + 1] } '--advisor' { $v.advisorModel = [string]$x[$i + 1] } }
    }
    return [pscustomobject]@{ Model = (Format-Model $v.model); Effort = $v.effortLevel; Advisor = (Format-Model $v.advisorModel); Configured = $true }
}

function Get-TranscriptInfo([string]$Path) {
    if (-not $Path) { return $NoInfo }
    try { $fi = [IO.FileInfo]::new($Path) } catch { return $NoInfo }
    if (-not $fi.Exists) { return $NoInfo }
    $key = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    $c = $script:InfoCache[$Path]
    if ($c -and $c.Key -eq $key) { return $c.Info }
    $info = $NoInfo
    try {
        foreach ($tail in 65536, 1048576, 8388608) {   # an entry can be large (tool input): widen the window if needed
            $j = Read-LastAssistant $fi.FullName $tail
            if ($j) {
                $adv = ''
                if ($j.PSObject.Properties['advisorModel']) { $adv = if ($j.advisorModel) { Format-Model ([string]$j.advisorModel) } else { 'off' } }
                $info = [pscustomobject]@{ Model = (Format-Model ([string]$j.message.model)); Effort = [string]$j.effort; Advisor = $adv }
                break
            }
            if ($tail -ge $fi.Length) { break }
        }
    } catch { }
    $script:InfoCache[$Path] = @{ Key = $key; Info = $info }
    return $info
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

# open: the window's shell (started by roost-run.ps1) runs and claude in it; exited: claude quit and the window is a
# plain shell (roost-run.ps1 marks run.json); none: no window (pid gone, or reused by another process)
function Get-RunState([string]$Name) {
    $f = Join-Path $RunDir "$Name.run.json"
    if (-not (Test-Path -LiteralPath $f)) { return 'none' }
    try {
        $r = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $p = Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue
        if (-not ($p -and ($p.StartTime.ToFileTimeUtc() -eq [int64]$r.start))) { return 'none' }
        if ($r.exited) { return 'exited' }
        return 'open'
    } catch { return 'none' }
}

# A session is "open" while claude runs in its window; parked and exited ones are what `roost restore` reopens.
function Test-Alive([string]$Name) { return ((Get-RunState $Name) -eq 'open') }

# claude.ai connectors on for this session? (config\connectors-allow: session names or *; the same rule as roost-run.ps1)
function Test-ConnAllowed([string]$Name) {
    if (-not (Test-Path -LiteralPath $ConnFile)) { return $true }
    return [bool](@(Get-Content -LiteralPath $ConnFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq '*' -or $_ -eq $Name })
}

function Format-Age([long]$Sec) {
    if ($Sec -lt 60) { return "${Sec}s" }
    if ($Sec -lt 3600) { return "$([math]::Floor($Sec / 60))m" }
    if ($Sec -lt 86400) { return "$([math]::Floor($Sec / 3600))h" }
    return "$([math]::Floor($Sec / 86400))d"
}

# parked (no window) | shell (claude exited, window stayed) | busy | attention (? needs a decision) | waiting (* your turn) | idle
function Get-StateKey($e, [string]$Run) {
    if ($Run -eq 'none') { return 'parked' }
    if ($Run -eq 'exited') { return 'shell' }
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
        $run = Get-RunState ([string]$e.name)
        $info = Get-TranscriptInfo ([string]$e.transcript)
        if (-not $info.Model) { $info = Get-ConfiguredInfo ([string]$e.name) ([string]$e.cwd) }   # no answer yet
        [pscustomobject]@{
            Name       = [string]$e.name
            State      = Get-StateKey $e $run
            Age        = Format-Age ($now - [long]$e.updated)
            Rc         = $(if ($run -eq 'open' -and $sid -and $rc.ContainsKey($sid)) { $rc[$sid] } else { '' })
            Model      = $info.Model
            Effort     = $info.Effort
            Advisor    = $info.Advisor
            Configured = [bool]$info.Configured
            Cwd        = Format-Path ([string]$e.cwd)
            Sid        = $sid.Substring(0, [Math]::Min(8, $sid.Length))
        }
    }
}

function Get-Counts($Rows) {
    $c = [ordered]@{}
    foreach ($k in $States.Keys) { $c[$k] = 0 }
    foreach ($r in $Rows) { $c[$r.State]++ }
    return $c
}

# "● 2  ? 1  * 0  ○ 3  ⏸ 1" (zero counts dimmed; "exited" only when there is one)
function Format-Counts($Counts) {
    $parts = foreach ($k in $Counts.Keys) {
        if ($k -eq 'shell' -and -not $Counts[$k]) { continue }
        $t = $States[$k].Glyph + ' ' + $Counts[$k]
        if ($Counts[$k]) { Paint $t $States[$k].Sgr } else { Paint $t $Faint }
    }
    return ($parts -join '  ')
}

# the optional MODEL / EFFORT / ADVISOR columns: as many as leave the directory column at least $MinDir wide
function Get-InfoColumns([int]$Free, [int]$MinDir = 16) {
    $cols = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @(@('MODEL', 'Model', 10), @('EFFORT', 'Effort', 6), @('ADVISOR', 'Advisor', 10))) {
        if ($Free - ($c[2] + 2) -lt $MinDir) { break }
        $cols.Add($c); $Free -= $c[2] + 2
    }
    return , $cols
}
# dim: a parked session, or values only configured so far (the session has not answered since it started)
function Format-InfoCells($Row, $Cols) {
    $s = ''
    foreach ($c in $Cols) {
        $t = Fit ([string]$Row.($c[1])) $c[2]
        $s += $(if ($Row.State -eq 'parked' -or $Row.Configured) { Paint $t $Dim } else { $t }) + '  '
    }
    return $s
}
function Format-InfoHeads($Cols) { $s = ''; foreach ($c in $Cols) { $s += (Fit $c[0] $c[2]) + '  ' }; return $s }

function Show-List {
    $rows = @(Get-Rows)
    if (-not $rows) { Write-Output ('no sessions yet - start one with:  ' + (Paint 'roost new NAME [DIR]' $Accent)); return }
    $nw = [Math]::Min(24, [Math]::Max(4, ($rows.Name | Measure-Object -Property Length -Maximum).Maximum))
    $sw = 11
    $free = (Get-Width) - 1 - (2 + $nw + 2 + $sw + 2 + 4 + 2 + 3 + 2 + 2 + 8)
    $cols = Get-InfoColumns $free
    foreach ($c in $cols) { $free -= $c[2] + 2 }
    $dw = [Math]::Max(16, $free)
    Write-Output ''
    Write-Output ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint "$($rows.Count) session(s)" $Dim) + '    ' + (Format-Counts (Get-Counts $rows)))
    Write-Output ''
    Write-Output (Paint ('  ' + (Fit 'NAME' $nw) + '  ' + (Fit 'STATE' $sw) + '  ' + (Fit 'AGE' 4) + '  ' + (Fit 'RC' 3) + '  ' + (Format-InfoHeads $cols) + (Fit 'DIRECTORY' $dw) + '  SESSION') $Dim)
    foreach ($r in $rows) {
        $name = Fit $r.Name $nw
        if ($r.State -in 'attention', 'waiting') { $name = Paint $name '1' }
        Write-Output ('  ' + $name + '  ' + (Format-State $r.State $sw) + '  ' + (Paint (Fit $r.Age 4) $Dim) + '  ' + (Format-Rc $r.Rc 3) + '  ' + (Format-InfoCells $r $cols) + (Fit $r.Cwd $dw -KeepEnd) + '  ' + (Paint $r.Sid $Dim))
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
# psmux 3.4.0's status line renderer (not display-message, which expands these fine) prints a window's RAW format
# when a #{?cond,yes,} has an EMPTY false branch, a nested #{...} in its true branch and cond is false. So no false
# branch here is empty: a zero-width style (#[default], or #[bold] inside the already bold current window) stands in.
# Check changes on the real bar with windows\probe-statusbar.ps1.
function Set-PcTheme {
    $first = '#{=1:window_name}'
    $bare = "#{s/^[${Dot}?*${Ring}] //:window_name}"   # name without the glyph (session names never contain these)
    $busy = "#{==:$first,$Dot}"; $ask = "#{==:$first,?}"; $wait = "#{==:$first,*}"; $idle = "#{==:$first,$Ring}"
    $shown = "#{||:#{==:#{window_name},dash},#{||:$busy,#{||:$ask,$wait}}}"
    $mark = "#{?$busy,#[fg=colour214] $Dot,#{?$ask,#[fg=colour201]#[bold] ?,#{?$wait,#[fg=colour51] *,#[default]}}}"
    $markCur = "#{?$busy, $Dot,#{?$ask, ?,#{?$wait, *,#{?$idle, $Ring,#[bold]}}}}"
    $opts = [ordered]@{
        'mouse'                        = 'on'
        'status-interval'              = '2'
        'allow-rename'                 = 'off'
        'status-style'                 = 'bg=colour235,fg=colour250'
        'status-left'                  = ' roost '
        'status-left-length'           = '8'
        'status-right-length'          = '60'          # status-right itself is pushed by the dash window
        'window-status-separator'      = ''
        'window-status-format'         = "#{?$shown, #I:$bare$mark#[default] ,#[default]}"
        'window-status-current-format' = "#[reverse]#[bold] #I:$bare$markCur #[default]"
        'pane-border-style'            = 'fg=colour238'
        'pane-active-border-style'     = 'fg=colour39'
        'message-style'                = 'bg=colour39,fg=colour16'
        'mode-style'                   = 'bg=colour39,fg=colour16'
        'set-titles'                   = 'on'          # the terminal tab says roost (the dash window adds the counts)
        'set-titles-string'            = "$Bird roost"
    }
    foreach ($k in $opts.Keys) { & psmux set-option -t $PcSess $k $opts[$k] 2>$null | Out-Null }
    # Ctrl+B a: jump to the next session that waits for you (like the Linux tmux.conf; key bindings are server-wide)
    & psmux bind-key a run-shell -b "pwsh -NoProfile -File `"$Self`" next #{session_name}" 2>$null | Out-Null
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
        if ($k -eq 'shell' -and -not $Counts[$k]) { continue }
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
# when it can; a session moved to a background job runs its hooks outside psmux and cannot. A window whose claude
# exited gets its bare name, so the status bar does not show a stale state for it.
function Sync-WinNames($Rows) {
    $want = @{}
    foreach ($r in $Rows) {
        if ($r.State -eq 'shell') { $want[$r.Name] = $r.Name }
        elseif ($r.State -ne 'parked') { $want[$r.Name] = $States[$r.State].Glyph + ' ' + $r.Name }
    }
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

# Variables a Claude Code tool shell (CLAUDECODE=1) carries for ITS session: nesting marker, session / bridge /
# messaging ids, and the tool-shell defaults (NO_COLOR, GIT_EDITOR=true, ...). psmux copies the caller's environment
# into a NEW session and every window of it inherits that, so a roost session started from such a shell would hand
# them to every claude it runs: CLAUDECODE alone makes claude refuse to start as a nested session. User settings such
# as CLAUDE_CODE_GIT_BASH_PATH are kept. roost-run.ps1 drops the same list again before it starts claude.
$ClaudeShellVars = '^(CLAUDECODE|CLAUDE_PID|CLAUDE_JOB_DIR|CLAUDE_ENV_FILE|CLAUDE_CODE_(ENTRYPOINT|SESSION_ID|BRIDGE_SESSION_ID|' +
'CHILD_SESSION|MESSAGING_SOCKET|MESSAGING_TOKEN|SESSION_ATTENDED|SSE_PORT|ALT_SCREEN_FULL_REPAINT|HOST_SHORT_TEMP_DIRS|' +
'DISABLE_TERMINAL_TITLE)|NO_COLOR|GIT_EDITOR|GIT_TERMINAL_PROMPT|GIT_ASKPASS|COREPACK_ENABLE_AUTO_PIN)$'
function Clear-ClaudeShellEnv {
    if (-not $env:CLAUDECODE) { return }
    foreach ($v in @(Get-ChildItem env: | Where-Object { $_.Name -match $ClaudeShellVars })) { Remove-Item "env:$($v.Name)" -ErrorAction SilentlyContinue }
}

# creates the psmux session (detached) with the "dash" window if it does not exist yet
function Initialize-Pc {
    if (Test-PcUp) { return }
    Clear-ClaudeShellEnv   # new-session copies our environment into the session
    $dashCmd = "pwsh -NoLogo -NoExit -File `"$Self`" dash"
    & psmux new-session -d -s $PcSess -n dash -c $env:USERPROFILE $dashCmd
    Set-PcTheme
}

# target ("roost:@N") of the session's window; its name is "NAME" or "<glyph> NAME" (the hook adds the glyph).
# Always session-qualified: psmux window ids are per session, so a bare @N can hit a window of another psmux session.
function Get-WinId([string]$Name, [string]$Not = '') {
    $rx = '^(\S\s)?' + [regex]::Escape($Name) + '$'
    foreach ($l in @(& psmux list-windows -t $PcSess -F '#{window_id}|#{window_name}' 2>$null)) {
        $p = "$l".Split('|', 2)
        if ($p.Count -eq 2 -and $p[1] -match $rx -and "${PcSess}:$($p[0])" -ne $Not) { return "${PcSess}:$($p[0])" }
    }
    return $null
}

function Start-Tab([string]$Name, [string]$Cwd, [string]$Sid, [string]$Prompt, [string[]]$Extra, [bool]$Conn = $false) {
    $extraList = @($Extra | Where-Object { $_ })
    $a = [ordered]@{ sid = $Sid; prompt = $Prompt; extra = $extraList; conn = $Conn }
    # the window gets its psmux session's environment, not ours: hand our overrides to roost-run.ps1 explicitly
    if ($env:ROOST_CLAUDE_BIN) { $a['bin'] = $env:ROOST_CLAUDE_BIN }
    if ($env:ROOST_PSMUX_SESSION) { $a['mux'] = $PcSess }
    [IO.File]::WriteAllText((Join-Path $RunDir "$Name.args.json"), ($a | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $dir = $Cwd.TrimEnd('\')
    $cmd = "pwsh -NoLogo -NoExit -File `"$Runner`" $Name"
    if ($env:ROOST_HOME) { $cmd += " -RoostHome `"$CsHome`"" }
    $wargs = @('new-window', '-d', '-t', "${PcSess}:", '-n', $Name, '-c', $dir, $cmd)
    if ($env:ROOST_DRY) { Write-Host ('psmux ' + ($wargs -join ' ')); return }
    Initialize-Pc
    $old = Get-WinId $Name   # a stale window: claude exited in it, or its session died
    & psmux @wargs
    if ($old) {
        # the old window goes last: this command may run inside it (`roost NAME` typed in an exited session's shell)
        if ($env:TMUX_PANE -and "$(& psmux display-message -p -t $old '#{pane_id}' 2>$null)".Trim() -eq $env:TMUX_PANE) {
            $new = Get-WinId $Name $old
            if ($new) { & psmux select-window -t $new 2>$null | Out-Null }
        }
        & psmux kill-window -t $old 2>$null | Out-Null
    }
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
        @('Ctrl+B a', 'next waiting'), @('Ctrl+B n/p', 'next / previous'), @('Ctrl+B w', 'all windows'), @('Ctrl+B d', 'detach')
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
                $free = $W - (3 + 3 + $sw + 2 + $nw + 2 + 4 + 2 + 3 + 2)
                $cols = Get-InfoColumns $free 12
                foreach ($c in $cols) { $free -= $c[2] + 2 }
                $dw = [Math]::Max(0, $free)
                $L.Add((Paint ('      ' + (Fit 'STATE' $sw) + '  ' + (Fit 'NAME' $nw) + '  ' + (Fit 'AGE' 4) + '  ' + (Fit 'RC' 3) + '  ' + (Format-InfoHeads $cols) + 'DIRECTORY') $Dim))
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
                        (Format-State $r.State $sw) + '  ' + $name + '  ' + (Paint (Fit $r.Age 4) $Dim) + '  ' + (Format-Rc $r.Rc 3) + '  ' +
                        (Format-InfoCells $r $cols) + (Fit $r.Cwd $dw -KeepEnd)
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
        # the session's last permission mode comes back (never bypassPermissions, as on Linux), and its connectors
        $extra = @()
        if ([string]$e.permission_mode -in 'default', 'acceptEdits', 'plan', 'auto', 'dontAsk') { $extra = @('--permission-mode', [string]$e.permission_mode) }
        $conn = ($e.connectors -eq $true) -or (Test-ConnAllowed ([string]$e.name))
        Start-Tab $e.name $cwd $sid $p $extra $conn
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
    $conn = $rest -contains '--connectors'   # roost's own flag, not claude's
    $rest = @($rest | Where-Object { $_ -ne '--connectors' })
    $dir = $null
    if ($rest.Count -gt 0 -and -not ([string]$rest[0]).StartsWith('-')) {
        $dir = [string]$rest[0]
        $rest = @($rest | Select-Object -Skip 1)
    }
    if (-not $dir) {
        # like Linux: $ROOST_PROJECT_ROOT\NAME (default ~\NAME) when that folder exists, else the current directory
        $root = if ($env:ROOST_PROJECT_ROOT) { $env:ROOST_PROJECT_ROOT } else { $env:USERPROFILE }
        $cand = Join-Path $root $name
        $dir = if (Test-Path -LiteralPath $cand -PathType Container) { $cand } else { (Get-Location).Path }
    }
    $dir = (Resolve-Path -LiteralPath $dir -ErrorAction Stop).Path
    if (Test-Alive $name) { Say "session '$name' is already open (roost $name switches to it)"; return }
    if ($rest.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $SessDir "$name.json"))) {
        Say "'$name' is parked - resuming it"
        Restore-Sessions $name $false
        Switch-To $name
        return
    }
    Start-Tab $name $dir '' '' $rest ($conn -or (Test-ConnAllowed $name))
    if (-not $env:ROOST_DRY) { Switch-To $name }
}

function Remove-Session([string]$Name, [bool]$Kill) {
    if (-not $Name -or -not (Test-Name $Name)) { throw 'usage: roost close|forget NAME' }
    $run = Get-RunState $Name
    $r = $null
    if ($run -ne 'none') { $r = Get-Content -LiteralPath (Join-Path $RunDir "$Name.run.json") -Raw | ConvertFrom-Json }
    # forget first: `roost close NAME` may run inside the very window it closes
    Remove-Item -LiteralPath (Join-Path $SessDir "$Name.json"), (Join-Path $SessDir "$Name.ask"), (Join-Path $RunDir "$Name.run.json"), (Join-Path $RunDir "$Name.args.json") -Force -ErrorAction SilentlyContinue
    if ($Kill) {
        $w = Get-WinId $Name
        if ($w -and $run -eq 'open') {
            # end claude cleanly, like Linux: Esc first (cancels a pending "?" prompt instead of answering it), then /exit
            & psmux send-keys -t $w Escape 2>$null | Out-Null
            Start-Sleep -Milliseconds 400
            & psmux send-keys -t $w -l '/exit' 2>$null | Out-Null
            & psmux send-keys -t $w Enter 2>$null | Out-Null
            for ($k = 0; $k -lt 20; $k++) {
                Start-Sleep -Milliseconds 250
                if (-not (Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue)) { break }
                if ((Get-Content -LiteralPath (Join-Path $RunDir "$Name.run.json") -Raw -ErrorAction SilentlyContinue) -match '"exited":true') { break }
            }
        }
        Say "removed $Name"
        Remove-Item -LiteralPath (Join-Path $RunDir "$Name.run.json") -Force -ErrorAction SilentlyContinue   # roost-run rewrites it as claude exits
        if ($r -and (Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue)) { & taskkill /PID ([int]$r.pid) /T /F 2>$null | Out-Null }
        if ($w) { & psmux kill-window -t $w 2>$null | Out-Null }
        return
    }
    Say "removed $Name"
}

# the window to jump to: "?" windows first, then "*", cycling on from the current one; $null when nothing waits.
# $Wins: objects with Id (@N) and Name ("? api"); the glyph in the name is the state (hook + Sync-WinNames).
function Get-NextWaiting($Wins, [string]$Current) {
    $ids = @(foreach ($g in '?', '*') { foreach ($w in $Wins) { if ("$($w.Name)".StartsWith("$g ")) { [string]$w.Id } } })
    if (-not $ids) { return $null }
    $i = [array]::IndexOf($ids, $Current)
    if ($i -lt 0) { return $ids[0] }
    return $ids[($i + 1) % $ids.Count]
}

# `roost next [SESSION]`: SESSION is passed by the Ctrl+B a binding (run-shell has no $TMUX); typed in a plain terminal
# it also attaches, like `roost NAME`
function Invoke-Next([string]$Session) {
    $s = if ($Session) { $Session } else { $PcSess }
    $wins = @(foreach ($l in @(& psmux list-windows -t $s -F '#{window_id}|#{window_name}' 2>$null)) {
            $p = "$l".Split('|', 2); if ($p.Count -eq 2) { [pscustomobject]@{ Id = $p[0]; Name = $p[1] } }
        })
    $pick = Get-NextWaiting $wins "$(& psmux display-message -p -t $s '#{window_id}' 2>$null)".Trim()
    if (-not $pick) {
        if ($Session -or $env:TMUX) { & psmux display-message -t $s 'roost: nothing waits for you' 2>$null | Out-Null } else { Say 'nothing waits for you' }
        return
    }
    & psmux select-window -t "${s}:$pick" 2>$null | Out-Null
    if (-not $Session -and -not $env:TMUX) { Invoke-Attach }
}

function Show-Doctor {
    function Ok([string]$k, [string]$m) { Write-Host ('  ' + (Paint $Tick $Green) + ' ' + (Fit $k 10) + ' ' + $m) }
    function Bad([string]$k, [string]$m) { Write-Host ('  ' + (Paint $Cross $Red) + ' ' + (Paint (Fit $k 10) '1') + ' ' + (Paint $m $Red)) }
    function Info([string]$k, [string]$m) { Write-Host ('  ' + (Paint $Mid $Dim) + ' ' + (Fit $k 10) + ' ' + (Paint $m $Dim)) }
    Write-Host ''
    Write-Host ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint 'doctor' $Dim))
    Write-Host ''
    foreach ($c in 'psmux', 'pwsh', 'claude', 'git') {
        $n = if ($c -eq 'claude' -and $env:ROOST_CLAUDE_BIN) { $env:ROOST_CLAUDE_BIN } else { $c }
        $g = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) { Ok $c (Format-Path $g.Source) } else { Bad $c "$n not found in PATH" }
    }
    $sp = Join-Path $env:USERPROFILE '.claude\settings.json'
    $hooks = if (Test-Path -LiteralPath $sp) { Get-Content -LiteralPath $sp -Raw } else { '' }
    if ($hooks -notmatch 'roost-hook\.ps1') { Bad 'hooks' 'missing in ~\.claude\settings.json (run install.ps1)' }
    elseif ($hooks -notmatch 'roost-hook\.ps1 resume') { Bad 'hooks' 'PostToolUse hook missing: "?" stays until the next stop (run install.ps1)' }
    else { Ok 'hooks' 'registered in ~\.claude\settings.json' }
    $startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'roost-restore.cmd'
    if (Test-Path -LiteralPath $startup) { Ok 'restore' 'reopens sessions at sign-in (Startup folder)' } else { Bad 'restore' 'restore-at-logon entry missing (run install.ps1)' }
    if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\roost\roost.json')) { Info 'terminal' 'Windows Terminal profile "roost" installed' }
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
        @('roost restore [NAME]', 'reopen parked sessions (no window) and exited ones'),
        @('roost close NAME', '/exit the session, close its window and forget it'),
        @('roost forget NAME', 'forget the registry entry only'),
        @('roost next', 'jump to the next session that waits for you (? first, then *)'),
        @('roost doctor', 'health check'),
        @('roost selftest', 'check the scripts without opening any window')
    )
    $keyRows = @(
        @("$Arrows  Enter  click", 'pick a session on the dashboard (or press its key)'),
        @('Ctrl+B a', 'next session that waits for you'),
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
    # child processes (hook, `roost new` / `restore`, roost-run.ps1) get the temp home through the environment; the
    # script-level paths of THIS process still point at the real home, so in-process checks swap them temporarily
    $saved = @{ H = $env:ROOST_HOME; N = $env:ROOST_NAME; D = $env:ROOST_DRY; S = $env:ROOST_STAGGER; B = $env:ROOST_CLAUDE_BIN; T = $env:ROOST_TITLES
        C = $script:ClaudeDir; R = $script:RunDir; F = $script:ConnFile }
    $env:ROOST_HOME = $tmp; $env:ROOST_NAME = 'selftest'; $env:ROOST_DRY = '1'; $env:ROOST_STAGGER = '0'
    $script:fails = 0; $script:checks = 0
    $hook = Join-Path $Here 'roost-hook.ps1'
    $reg = Join-Path $tmp 'sessions\selftest.json'
    $flag = Join-Path $tmp 'sessions\selftest.ask'
    $check = {
        param($label, $cond)
        $script:checks++
        if ($cond) { Write-Host ('  ' + (Paint $Tick $Green) + ' ' + $label) }
        else { Write-Host ('  ' + (Paint $Cross $Red) + ' ' + (Paint $label $Red)); $script:fails++ }
    }
    $call = { param($ev, $json) $json | & pwsh -NoProfile -File $hook $ev }
    $read = { Get-Content -LiteralPath $reg -Raw | ConvertFrom-Json }
    $json = { param($path) Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    Write-Host ''
    Write-Host ('  ' + (Paint ' roost ' $Badge) + '  ' + (Paint 'selftest' $Dim))
    Write-Host ''
    try {
        foreach ($d in 'sessions', 'run', 'config', 'claude\sessions') { New-Item -ItemType Directory -Force -Path (Join-Path $tmp $d) | Out-Null }
        # ---- hook
        $j0 = @{ session_id = 'sid-1'; cwd = $tmp; transcript_path = 'x' } | ConvertTo-Json -Compress
        $o = & $call 'start' (@{ session_id = 'sid-1'; cwd = $tmp; transcript_path = 'x'; permission_mode = 'plan' } | ConvertTo-Json -Compress)
        & $check 'hook is silent on stdout' (-not $o)
        & $check 'start registers the session' (Test-Path -LiteralPath $reg)
        $r = & $read; & $check 'start -> idle' (($r.state -eq 'idle') -and ($r.display -eq 'idle'))
        & $check 'permission mode is recorded' ($r.permission_mode -eq 'plan')
        & $call 'busy' $j0 | Out-Null
        $r = & $read; & $check 'busy' (($r.state -eq 'busy') -and ($r.display -eq 'busy'))
        & $check 'an event without permission_mode keeps the last one' ($r.permission_mode -eq 'plan')
        & $call 'attention' '{"session_id":"sid-1","notification_type":"permission_prompt"}' | Out-Null
        $r = & $read; & $check 'permission prompt -> ? (state stays busy), "?" flag set' (($r.display -eq 'attention') -and ($r.state -eq 'busy') -and (Test-Path -LiteralPath $flag))
        & $call 'resume' $j0 | Out-Null
        $r = & $read; & $check 'PostToolUse after the prompt -> busy, flag cleared' (($r.display -eq 'busy') -and -not (Test-Path -LiteralPath $flag))
        & $call 'attention' '{"session_id":"sid-1","notification_type":"permission_prompt"}' | Out-Null
        & $call 'idle' $j0 | Out-Null
        $r = & $read; & $check 'stop -> * waiting, state idle, flag cleared' (($r.display -eq 'waiting') -and ($r.state -eq 'idle') -and -not (Test-Path -LiteralPath $flag))
        & $call 'resume' $j0 | Out-Null
        $r = & $read; & $check 'PostToolUse does nothing unless "?"' ($r.display -eq 'waiting')
        & $call 'end' '{"reason":"other"}' | Out-Null
        & $check 'end(other) keeps the entry' (Test-Path -LiteralPath $reg)
        & $call 'end' '{"reason":"prompt_input_exit"}' | Out-Null
        & $check '/exit forgets the entry' (-not (Test-Path -LiteralPath $reg))
        # ---- new / restore (dry run: the psmux command is printed, run\NAME.args.json is what roost-run.ps1 would get)
        $out = (& pwsh -NoProfile -File $Self new selftab $tmp -c | Out-String)
        & $check 'new prints a psmux command (dry run)' ($out -match 'new-window.* -n selftab')
        $af = Join-Path $tmp 'run\selftab.args.json'
        & $check 'extra args are passed on (-c)' ((Test-Path -LiteralPath $af) -and ((Get-Content -LiteralPath $af -Raw) -match '"-c"'))
        Set-Content -LiteralPath (Join-Path $tmp 'config\resume-prompt.txt') -Value 'please continue'
        Set-Content -LiteralPath (Join-Path $tmp 'config\connectors-allow') -Value 'someone-else'
        Set-Content -LiteralPath (Join-Path $tmp 'tr.jsonl') -Value '{}'
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        @{ name = 'r-busy'; cwd = $tmp; session_id = 'sid-b'; transcript = (Join-Path $tmp 'tr.jsonl'); state = 'busy'; display = 'busy'; permission_mode = 'plan'; connectors = $true; updated = $now } |
            ConvertTo-Json -Compress | Set-Content (Join-Path $tmp 'sessions\r-busy.json')
        @{ name = 'r-idle'; cwd = $tmp; session_id = 'sid-i'; transcript = (Join-Path $tmp 'tr.jsonl'); state = 'idle'; display = 'waiting'; permission_mode = 'bypassPermissions'; connectors = $false; updated = $now } |
            ConvertTo-Json -Compress | Set-Content (Join-Path $tmp 'sessions\r-idle.json')
        & pwsh -NoProfile -File $Self restore 6>$null | Out-Null
        $b = & $json (Join-Path $tmp 'run\r-busy.args.json'); $i = & $json (Join-Path $tmp 'run\r-idle.args.json')
        & $check 'restore: --resume id, and the continue prompt for a busy session' (($b.sid -eq 'sid-b') -and ($b.prompt -eq 'please continue'))
        & $check 'restore: no prompt for an idle session' (($i.sid -eq 'sid-i') -and -not $i.prompt)
        & $check 'restore: the permission mode comes back (never bypassPermissions)' ((($b.extra -join ' ') -eq '--permission-mode plan') -and -not $i.extra)
        & $check 'restore: connectors as recorded / as connectors-allow says' (($b.conn -eq $true) -and ($i.conn -eq $false))
        # ---- roost-run.ps1 for real, with a fake claude that logs what it got
        $fake = Join-Path $tmp 'fake-claude.ps1'
        Set-Content -LiteralPath $fake -Value ('Set-Content -LiteralPath (Join-Path $env:ROOST_HOME "fake.log") -Value @(("ARGS " + ($args -join " ")), ' +
            '("MCP=" + $env:ENABLE_CLAUDEAI_MCP_SERVERS), ("NAME=" + $env:ROOST_NAME), ("LEAK=" + $env:CLAUDECODE + $env:CLAUDE_CODE_SESSION_ID))')
        Set-Content -LiteralPath (Join-Path $tmp 'config\claude-flags') -Value '--permission-mode auto --verbose'
        @{ sid = 'sid-9'; prompt = 'go on'; extra = @('--permission-mode', 'plan'); conn = $false } | ConvertTo-Json -Compress | Set-Content (Join-Path $tmp 'run\runtest.args.json')
        # as if this psmux session had been created from a Claude Code tool shell
        $cc = @{ C = $env:CLAUDECODE; S = $env:CLAUDE_CODE_SESSION_ID }
        $env:ROOST_CLAUDE_BIN = $fake; $env:ROOST_TITLES = '0'; $env:CLAUDECODE = '1'; $env:CLAUDE_CODE_SESSION_ID = 'other-session'
        & pwsh -NoProfile -File $Runner runtest | Out-Null
        $env:ROOST_CLAUDE_BIN = $saved.B; $env:ROOST_TITLES = $saved.T; $env:CLAUDECODE = $cc.C; $env:CLAUDE_CODE_SESSION_ID = $cc.S
        $log = Get-Content -LiteralPath (Join-Path $tmp 'fake.log') -ErrorAction SilentlyContinue
        & $check 'run: flags + --resume id + extra args + prompt, in that order' ($log -contains 'ARGS --verbose --resume sid-9 --permission-mode plan go on')
        & $check 'run: claude.ai connectors off unless allowed; ROOST_NAME set' (($log -contains 'MCP=false') -and ($log -contains 'NAME=runtest'))
        & $check "run: a Claude Code shell's CLAUDECODE / session id never reach claude" ($log -contains 'LEAK=')
        & $check 'run: marks the window "exited" when claude quits' ((& $json (Join-Path $tmp 'run\runtest.run.json')).exited -eq $true)
        # ---- in-process logic
        $script:RunDir = Join-Path $tmp 'run'
        $st = (Get-Process -Id $PID).StartTime.ToFileTimeUtc()
        @{ pid = $PID; start = $st } | ConvertTo-Json -Compress | Set-Content (Join-Path $tmp 'run\live.run.json')
        @{ pid = $PID; start = $st; exited = $true } | ConvertTo-Json -Compress | Set-Content (Join-Path $tmp 'run\gone.run.json')
        @{ pid = $PID; start = 1 } | ConvertTo-Json -Compress | Set-Content (Join-Path $tmp 'run\reused.run.json')
        & $check 'run state: open / exited (window stayed, claude quit) / reused pid' (((Get-RunState 'live') -eq 'open') -and ((Get-RunState 'gone') -eq 'exited') -and ((Get-RunState 'reused') -eq 'none'))
        & $check 'an exited session shows as "exited" and is not alive' (((Get-StateKey ([pscustomobject]@{ display = 'busy' }) 'exited') -eq 'shell') -and -not (Test-Alive 'gone'))
        $w = @([pscustomobject]@{ Id = '@1'; Name = 'dash' }, [pscustomobject]@{ Id = '@2'; Name = '* b' }, [pscustomobject]@{ Id = '@3'; Name = '? a' },
            [pscustomobject]@{ Id = '@4'; Name = "$Dot c" }, [pscustomobject]@{ Id = '@5'; Name = '? d' })
        & $check 'next: "?" first, then "*", cycling' (((Get-NextWaiting $w '@1') -eq '@3') -and ((Get-NextWaiting $w '@3') -eq '@5') -and
            ((Get-NextWaiting $w '@5') -eq '@2') -and ((Get-NextWaiting $w '@2') -eq '@3') -and ($null -eq (Get-NextWaiting @($w[0], $w[3]) '@1')))
        $tr = Join-Path $tmp 'transcript.jsonl'
        $big = 'x' * 100000   # the last entry is larger than the first tail read
        @('{"type":"user","message":{"content":"hi"}}',
            (@{ type = 'assistant'; message = @{ model = 'claude-opus-5-5'; content = $big }; effort = 'max'; advisorModel = 'claude-opus-5-5' } | ConvertTo-Json -Compress),
            (@{ type = 'assistant'; isSidechain = $true; message = @{ model = 'claude-haiku-5-5' }; effort = 'low' } | ConvertTo-Json -Compress)) | Set-Content -LiteralPath $tr
        $ti = Get-TranscriptInfo $tr
        & $check 'model / effort / advisor from the transcript (subagent entries skipped)' (($ti.Model -eq 'opus 5.5') -and ($ti.Effort -eq 'max') -and ($ti.Advisor -eq 'opus 5.5'))
        & $check 'model names: claude-3-5-sonnet-20241022 -> sonnet 3.5, claude-fable-5-1 -> fable 5.1' (((Format-Model 'claude-3-5-sonnet-20241022') -eq 'sonnet 3.5') -and ((Format-Model 'claude-fable-5-1') -eq 'fable 5.1'))
        $compiled = try { if (-not ('RoostDashInput' -as [type])) { Add-Type -TypeDefinition $DashInputSrc }; $true } catch { $false }
        & $check 'dashboard mouse input compiles' $compiled
        # Remote Control state from Claude Code's per-process files (fake ones for this process, plus a stale one)
        $cs = Join-Path $tmp 'claude\sessions'
        @{ pid = $PID; procStart = $st; sessionId = 'sid-on'; bridgeSessionId = 'session_x' } | ConvertTo-Json | Set-Content (Join-Path $cs 'a.json')
        @{ pid = $PID; procStart = $st; sessionId = 'sid-off'; bridgeSessionId = '' } | ConvertTo-Json | Set-Content (Join-Path $cs 'b.json')
        @{ pid = $PID; procStart = 1; sessionId = 'sid-stale'; bridgeSessionId = 'session_y' } | ConvertTo-Json | Set-Content (Join-Path $cs 'c.json')
        $script:ClaudeDir = Join-Path $tmp 'claude'
        $rc = Get-RcIndex
        & $check 'Remote Control: on / off / stale pid ignored' (($rc['sid-on'] -eq 'on') -and ($rc['sid-off'] -eq 'off') -and -not $rc.ContainsKey('sid-stale'))
        # before its first answer a session shows what it is configured to use: launch flags over settings
        '{"model":"opus","effortLevel":"xhigh","advisorModel":"opus"}' | Set-Content (Join-Path $tmp 'claude\settings.json')
        @{ sid = ''; extra = @('--model', 'claude-sonnet-5-5', '--effort', 'low') } | ConvertTo-Json -Compress | Set-Content (Join-Path $tmp 'run\cfgtest.args.json')
        $ci = Get-ConfiguredInfo 'cfgtest' $tmp; $cd = Get-ConfiguredInfo 'noflags' $tmp
        & $check 'configured model / effort / advisor: launch flags over settings' (($ci.Model -eq 'sonnet 5.5') -and ($ci.Effort -eq 'low') -and ($ci.Advisor -eq 'opus') -and
            ($cd.Model -eq 'opus') -and ($cd.Effort -eq 'xhigh') -and $ci.Configured)
        & $check 'psmux is installed' ([bool](Get-Command psmux -ErrorAction SilentlyContinue))
        $cb = if ($saved.B) { $saved.B } else { 'claude' }
        & $check 'claude is installed' ([bool](Get-Command $cb -ErrorAction SilentlyContinue))
    } finally {
        $env:ROOST_HOME = $saved.H; $env:ROOST_NAME = $saved.N; $env:ROOST_DRY = $saved.D; $env:ROOST_STAGGER = $saved.S
        $env:ROOST_CLAUDE_BIN = $saved.B; $env:ROOST_TITLES = $saved.T
        $script:ClaudeDir = $saved.C; $script:RunDir = $saved.R; $script:ConnFile = $saved.F
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
        'next' { Invoke-Next ([string]$rest[0]) }
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
