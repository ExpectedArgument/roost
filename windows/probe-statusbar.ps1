#requires -Version 7
# Read-only probe: shows the psmux status bar as a terminal really draws it. `psmux display-message '#{E:...}'` is NOT
# enough: the status line renderer handles some formats differently (see Set-PcTheme in roost.ps1).
# It copies the status options and window names of a live psmux session (default "roost"; only list/show commands
# touch it) into a throw-away server `psmux -L roost-statusprobe`, attaches a client there inside a pseudoconsole (the
# path Windows Terminal uses), and prints the status line text with the style of every run. -Click 'LABEL|LABEL' then
# clicks those status bar labels (SGR mouse reports on the client's input) and prints which window became active.
#   pwsh -File windows\probe-statusbar.ps1 [-Session roost] [-Click '0:dash|3:api'] [-Width 120] [-Height 30]
param([string]$Session = 'roost', [string]$Click = '', [int]$Width = 120, [int]$Height = 30)
$ErrorActionPreference = 'Stop'
$L = 'roost-statusprobe'
$psmux = (Get-Command psmux).Source

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class ProbePty {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll")] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
    static IntPtr pc; static FileStream input, output; static PROCESS_INFORMATION pi;
    static readonly StringBuilder buf = new StringBuilder(); static readonly object gate = new object();

    public static void Start(string cmd, short cols, short rows) {
        SafeFileHandle inR, inW, outR, outW;
        CreatePipe(out inR, out inW, IntPtr.Zero, 0);
        CreatePipe(out outR, out outW, IntPtr.Zero, 0);
        int hr = CreatePseudoConsole(new COORD { X = cols, Y = rows }, inR, outW, 0, out pc);
        if (hr != 0) throw new Exception("CreatePseudoConsole failed: " + hr);
        inR.Dispose(); outW.Dispose();
        input = new FileStream(inW, FileAccess.Write); output = new FileStream(outR, FileAccess.Read);
        var si = new STARTUPINFOEX(); si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.StartupInfo.dwFlags = 0x100;   // STARTF_USESTDHANDLES with null handles: the child must not inherit our redirected pipes
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        si.lpAttributeList = Marshal.AllocHGlobal(size);
        if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref size)) throw new Exception("InitializeProcThreadAttributeList: " + Marshal.GetLastWin32Error());
        if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, (IntPtr)0x00020016, pc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw new Exception("UpdateProcThreadAttribute: " + Marshal.GetLastWin32Error());
        if (!CreateProcessW(null, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, null, ref si, out pi)) throw new Exception("CreateProcess: " + Marshal.GetLastWin32Error());
        var t = new Thread(() => {
            var b = new byte[65536]; var dec = Encoding.UTF8.GetDecoder(); var chars = new char[131072];
            try { int n; while ((n = output.Read(b, 0, b.Length)) > 0) { int c = dec.GetChars(b, 0, n, chars, 0); lock (gate) buf.Append(chars, 0, c); } } catch { }
        });
        t.IsBackground = true; t.Start();
    }
    public static void Write(string s) { var b = Encoding.UTF8.GetBytes(s); input.Write(b, 0, b.Length); input.Flush(); }
    public static string Take() { lock (gate) { var s = buf.ToString(); buf.Clear(); return s; } }
    public static void Stop() {
        try { TerminateProcess(pi.hProcess, 0); } catch { }
        var t = new Thread(() => { try { ClosePseudoConsole(pc); } catch { } }); t.IsBackground = true; t.Start(); t.Join(3000);
    }
}

// a minimal screen model: cursor moves, erases, text, and the effective SGR style of every cell
public static class ProbeScreen {
    static int Rows, Cols, cr, cc; static char[,] G; static string[,] S;
    static string fg = "", bg = ""; static bool bold, rev;
    public static void Reset(int rows, int cols) {
        Rows = rows; Cols = cols; G = new char[rows, cols]; S = new string[rows, cols];
        for (int r = 0; r < rows; r++) for (int c = 0; c < cols; c++) { G[r, c] = ' '; S[r, c] = ""; }
    }
    static string Style() { var s = new StringBuilder(); if (fg != "") s.Append("fg=" + fg + " "); if (bg != "") s.Append("bg=" + bg + " "); if (bold) s.Append("bold "); if (rev) s.Append("reverse "); return s.ToString().Trim(); }
    static int P(string p, int i) { var a = p.Split(';'); int v; return (i < a.Length && int.TryParse(a[i], out v)) ? v : -1; }
    static int N(string p, int i) { int v = P(p, i); return v <= 0 ? 1 : v; }
    static void Erase(int r, int from, int to) { for (int c = Math.Max(0, from); c <= Math.Min(Cols - 1, to); c++) { G[r, c] = ' '; S[r, c] = Style(); } }
    static void Sgr(string p) {
        var a = p.Length == 0 ? new[] { "0" } : p.Split(';');
        for (int i = 0; i < a.Length; i++) {
            int v; if (!int.TryParse(a[i], out v)) continue;
            if (v == 0) { fg = bg = ""; bold = rev = false; }
            else if (v == 1) bold = true; else if (v == 22) bold = false; else if (v == 7) rev = true; else if (v == 27) rev = false;
            else if (v >= 30 && v <= 37) fg = "ansi" + (v - 30); else if (v >= 90 && v <= 97) fg = "ansi" + (v - 82); else if (v == 39) fg = "";
            else if (v >= 40 && v <= 47) bg = "ansi" + (v - 40); else if (v >= 100 && v <= 107) bg = "ansi" + (v - 92); else if (v == 49) bg = "";
            else if ((v == 38 || v == 48) && i + 2 < a.Length && a[i + 1] == "5") { string c = "colour" + a[i + 2]; if (v == 38) fg = c; else bg = c; i += 2; }
            else if ((v == 38 || v == 48) && i + 4 < a.Length && a[i + 1] == "2") { string c = "#" + int.Parse(a[i + 2]).ToString("x2") + int.Parse(a[i + 3]).ToString("x2") + int.Parse(a[i + 4]).ToString("x2"); if (v == 38) fg = c; else bg = c; i += 4; }
        }
    }
    static void Csi(string p, char f) {
        if (p.Length > 0 && (p[0] == '?' || p[0] == '>' || p[0] == '=')) return;
        switch (f) {
            case 'H': case 'f': cr = Math.Min(Rows - 1, N(p, 0) - 1); cc = Math.Min(Cols - 1, N(p, 1) - 1); break;
            case 'G': cc = Math.Min(Cols - 1, N(p, 0) - 1); break;
            case 'd': cr = Math.Min(Rows - 1, N(p, 0) - 1); break;
            case 'C': cc = Math.Min(Cols - 1, cc + N(p, 0)); break;
            case 'D': cc = Math.Max(0, cc - N(p, 0)); break;
            case 'A': cr = Math.Max(0, cr - N(p, 0)); break;
            case 'B': cr = Math.Min(Rows - 1, cr + N(p, 0)); break;
            case 'X': Erase(cr, cc, cc + N(p, 0) - 1); break;
            case 'K': { int m = Math.Max(0, P(p, 0)); if (m == 0) Erase(cr, cc, Cols - 1); else if (m == 1) Erase(cr, 0, cc); else Erase(cr, 0, Cols - 1); break; }
            case 'J': { int m = Math.Max(0, P(p, 0)); if (m >= 2) { for (int r = 0; r < Rows; r++) Erase(r, 0, Cols - 1); } else if (m == 0) { Erase(cr, cc, Cols - 1); for (int r = cr + 1; r < Rows; r++) Erase(r, 0, Cols - 1); } break; }
            case 'm': Sgr(p); break;
        }
    }
    public static void Feed(string s) {
        int i = 0;
        while (i < s.Length) {
            char ch = s[i];
            if (ch == '\x1b' && i + 1 < s.Length) {
                char k = s[i + 1];
                if (k == '[') { int j = i + 2; while (j < s.Length && (s[j] < 0x40 || s[j] > 0x7E)) j++; if (j >= s.Length) return; Csi(s.Substring(i + 2, j - i - 2), s[j]); i = j + 1; continue; }
                if (k == ']' || k == 'P' || k == '_') { int j = i + 2; while (j < s.Length && s[j] != '\x07' && !(s[j] == '\x1b' && j + 1 < s.Length && s[j + 1] == '\\')) j++; i = (j < s.Length && s[j] == '\x07') ? j + 1 : j + 2; continue; }
                i += 2; continue;
            }
            if (ch == '\r') { cc = 0; i++; continue; }
            if (ch == '\n') { if (cr < Rows - 1) cr++; i++; continue; }
            if (ch == '\b') { if (cc > 0) cc--; i++; continue; }
            if (ch < 32) { i++; continue; }
            if (char.IsHighSurrogate(ch)) { Put('#'); Put('#'); i += 2; continue; }
            Put(ch); i++;
        }
    }
    // after the last column the cursor waits; the next character wraps to the next row (renderers rely on autowrap)
    static void Put(char ch) { if (cc >= Cols) { cc = 0; if (cr < Rows - 1) cr++; } G[cr, cc] = ch; S[cr, cc] = Style(); cc++; }
    public static string Row(int r) { var sb = new StringBuilder(); for (int c = 0; c < Cols; c++) sb.Append(G[r, c]); return sb.ToString(); }
    public static string Runs(int r) {
        var sb = new StringBuilder(); int s = 0; string row = Row(r);
        for (int c = 1; c <= Cols; c++) {
            if (c == Cols || S[r, c] != S[r, s]) { sb.Append(string.Format("  {0,3}-{1,-3} {2,-34} \"{3}\"\n", s, c - 1, "[" + S[r, s] + "]", row.Substring(s, c - s))); s = c; }
        }
        return sb.ToString();
    }
}
'@

function Mux { & $psmux -L $L @args 2>$null }
& $psmux has-session -t $Session 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw "no psmux session '$Session' to copy" }
Mux kill-server | Out-Null

# replica: same window names (and indices) and the same status options, in the throw-away server
$wins = @(& $psmux list-windows -t $Session -F '#{window_index}|#{window_active}|#{window_name}')
$active = 0; $made = $false
foreach ($w in $wins) {
    $idx, $act, $name = $w.Split('|', 3)
    if ($act -eq '1') { $active = $idx }
    if (-not $made) { Mux new-session -d -s probe -n $name -x $Width -y ($Height - 1) -- cmd.exe /k | Out-Null; Mux move-window -s probe:0 -t "probe:$idx" | Out-Null; $made = $true }
    else { Mux new-window -d -t "probe:$idx" -n $name -- cmd.exe /k | Out-Null }
}
$opts = 'mouse', 'status-interval', 'status-justify', 'status-style', 'status-left', 'status-left-length', 'status-right',
'status-right-length', 'window-status-separator', 'window-status-format', 'window-status-current-format'
foreach ($o in $opts) { Mux set-option -t probe $o ((& $psmux show-options -t $Session -v $o 2>$null) -join "`n") | Out-Null }
Mux select-window -t "probe:$active" | Out-Null

# client in a pseudoconsole, with the environment of a normal terminal tab
$keep = @{}
foreach ($v in @(Get-ChildItem env: | Where-Object { $_.Name -match '^(PSMUX|TMUX|NO_COLOR$)' -and $_.Name -ne 'PSMUX_VT_INPUT' })) { $keep[$v.Name] = $v.Value; Remove-Item "env:$($v.Name)" }   # PSMUX_VT_INPUT is the client's input route: keep it
$palette = '0c0c0c,c50f1f,13a10e,c19c00,0037da,881798,3a96dd,cccccc,767676,e74856,16c60c,f9f1a5,3b78ff,b4009e,61d6d6,f2f2f2'.Split(',')
if ($keep['PSMUX_HOST_COLORS']) { foreach ($kv in $keep['PSMUX_HOST_COLORS'].Split(',')) { $k, $v = $kv.Split('=', 2); if ($k -match '^\d+$' -and [int]$k -lt 16) { $palette[[int]$k] = $v } } }
$E = [char]27
[ProbeScreen]::Reset($Height, $Width)
try {
    [ProbePty]::Start("`"$psmux`" -L $L attach -t probe", $Width, $Height)
    function Pump([int]$Ms) {
        Start-Sleep -Milliseconds $Ms
        $o = [ProbePty]::Take()
        foreach ($m in [regex]::Matches($o, "\x1b\]4;(\d+);\?")) {   # palette queries, answered like Windows Terminal
            $n = [int]$m.Groups[1].Value; $h = $palette[$n]
            [ProbePty]::Write("$E]4;$n;rgb:$($h.Substring(0,2) * 2)/$($h.Substring(2,2) * 2)/$($h.Substring(4,2) * 2)$E\")
        }
        if ($o.Contains("$E[?996n")) { [ProbePty]::Write("$E[?997;1n") }
        if ($o.Contains("$E[6n")) { [ProbePty]::Write("$E[1;1R") }
        if ($o.Contains("$E[c") -or $o.Contains("$E[0c")) { [ProbePty]::Write("$E[?61;6;7;22;23;24;28;32;42c") }
        [ProbeScreen]::Feed($o)
    }
    Pump 3500; Pump 1500
    $last = $Height - 1
    Write-Host "status line of a copy of '$Session' ($Width columns):"
    Write-Host ('[' + [ProbeScreen]::Row($last) + ']')
    Write-Host 'runs (columns, style, text):'
    Write-Host ([ProbeScreen]::Runs($last))
    foreach ($lab in @($Click -split '\|' | Where-Object { $_ })) {
        $x = [ProbeScreen]::Row($last).IndexOf($lab)
        if ($x -lt 0) { Write-Host "click '$lab': not on the bar"; continue }
        $col = $x + 2
        [ProbePty]::Write("$E[<0;$col;${Height}M"); Start-Sleep -Milliseconds 80; [ProbePty]::Write("$E[<0;$col;${Height}m")
        Pump 1500
        Write-Host "click '$lab' (column $col) -> window $(Mux display-message -p -t probe '#I:#{window_name}')"
    }
} finally {
    [ProbePty]::Stop()
    Mux kill-server | Out-Null
    foreach ($k in $keep.Keys) { Set-Item "env:$k" $keep[$k] }
}
