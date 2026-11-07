# Runs inside a psmux window opened by `roost`: starts claude for session NAME.
# A psmux window gets its psmux session's environment (copied from whoever created the session), not the caller's, so
# `roost` hands over its overrides here: -RoostHome for ROOST_HOME, and bin / mux (ROOST_CLAUDE_BIN /
# ROOST_PSMUX_SESSION) in run\NAME.args.json.
param([Parameter(Mandatory)][string]$Name, [string]$RoostHome)

# a session created from a Claude Code tool shell carries that shell's variables; claude must not see them (CLAUDECODE
# makes it refuse to start, the ids belong to another session). Same list as $ClaudeShellVars in roost.ps1.
if ($env:CLAUDECODE) {
    $drop = '^(CLAUDECODE|CLAUDE_PID|CLAUDE_JOB_DIR|CLAUDE_ENV_FILE|CLAUDE_CODE_(ENTRYPOINT|SESSION_ID|BRIDGE_SESSION_ID|' +
    'CHILD_SESSION|MESSAGING_SOCKET|MESSAGING_TOKEN|SESSION_ATTENDED|SSE_PORT|ALT_SCREEN_FULL_REPAINT|HOST_SHORT_TEMP_DIRS|' +
    'DISABLE_TERMINAL_TITLE)|NO_COLOR|GIT_EDITOR|GIT_TERMINAL_PROMPT|GIT_ASKPASS|COREPACK_ENABLE_AUTO_PIN)$'
    foreach ($v in @(Get-ChildItem env: | Where-Object { $_.Name -match $drop })) { Remove-Item "env:$($v.Name)" -ErrorAction SilentlyContinue }
}
if ($RoostHome) { $env:ROOST_HOME = $RoostHome }   # the hooks (claude's children) need it too
$csHome = if ($env:ROOST_HOME) { $env:ROOST_HOME } else { Join-Path $env:LOCALAPPDATA 'roost' }
$env:ROOST_NAME = $Name   # the hooks only act when this is set

$argsFile = Join-Path $csHome "run\$Name.args.json"
$a = [pscustomobject]@{ sid = ''; prompt = ''; extra = @(); conn = $false }
if (Test-Path -LiteralPath $argsFile) { $a = Get-Content -LiteralPath $argsFile -Raw -Encoding utf8 | ConvertFrom-Json }
$extra = @($a.extra | Where-Object { $_ })
if ($a.mux) { $env:ROOST_PSMUX_SESSION = [string]$a.mux }

$flags = @()
$flagsFile = Join-Path $csHome 'config\claude-flags'
if (Test-Path -LiteralPath $flagsFile) { $flags = @((Get-Content -LiteralPath $flagsFile -Raw).Trim() -split '\s+' | Where-Object { $_ }) }

$cargs = [System.Collections.Generic.List[string]]::new()
$skipNext = $false
foreach ($x in $flags) {
    if ($skipNext) { $skipNext = $false; continue }
    # an explicit --permission-mode in the extra args replaces the default one
    if ($x -eq '--permission-mode' -and ($extra -contains '--permission-mode')) { $skipNext = $true; continue }
    $cargs.Add($x)
}
if ($a.sid) { $cargs.Add('--resume'); $cargs.Add([string]$a.sid) }
foreach ($x in $extra) { $cargs.Add([string]$x) }
if ($a.prompt) { $cargs.Add([string]$a.prompt) }

# claude.ai connectors (MCP servers): on when `roost new --connectors` asked for them or config\connectors-allow lists
# this session (or "*"; a missing file counts as "*"). Off saves tokens. ROOST_CONN tells the hook to record it.
$allow = Join-Path $csHome 'config\connectors-allow'
$conn = [bool]$a.conn -or -not (Test-Path -LiteralPath $allow) -or
    [bool](@(Get-Content -LiteralPath $allow) | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq '*' -or $_ -eq $Name })
if ($conn) { $env:ROOST_CONN = '1' } else { $env:ENABLE_CLAUDEAI_MCP_SERVERS = 'false' }

# lets `roost` know this window is open (used to tell open sessions from parked ones); "exited" marks a window whose
# claude has quit, which `roost restore` reopens
$runFile = Join-Path $csHome "run\$Name.run.json"
$me = Get-Process -Id $PID
$runInfo = [ordered]@{ pid = $PID; start = $me.StartTime.ToFileTimeUtc() }
[IO.File]::WriteAllText($runFile, ($runInfo | ConvertTo-Json -Compress))

# Outside psmux the tab title shows the session state: ● working  ? needs your decision  * waiting for your message  ○ quiet.
# A background runspace polls the registry and writes the terminal-title escape sequence. EXPERIMENTAL:
# disable with  $env:ROOST_TITLES = '0'  (then the tab simply keeps claude's own title).
$titles = $null
if ($env:TMUX) {
    $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'   # inside psmux the hook puts the state glyph in the window name
} elseif ($env:ROOST_TITLES -ne '0') {
    $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'   # otherwise claude overwrites our title
    try {
        $regPath = Join-Path $csHome "sessions\$Name.json"
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $titles = [powershell]::Create()
        $titles.Runspace = $rs
        [void]$titles.AddScript({
                param($reg, $name)
                $esc = [char]27; $bel = [char]7
                while ($true) {
                    try {
                        $d = 'idle'
                        if (Test-Path -LiteralPath $reg) { $d = [string](Get-Content -LiteralPath $reg -Raw | ConvertFrom-Json).display }
                        $g = switch ($d) { 'busy' { [string][char]0x25CF } 'attention' { '?' } 'waiting' { '*' } default { [string][char]0x25CB } }
                        [Console]::Out.Write("$esc]0;$g $name$bel")
                        [Console]::Out.Flush()
                    } catch { }
                    Start-Sleep -Milliseconds 2000
                }
            }).AddArgument($regPath).AddArgument($Name)
        [void]$titles.BeginInvoke()
    } catch { }
}

$arr = $cargs.ToArray()
$bin = if ($a.bin) { [string]$a.bin } elseif ($env:ROOST_CLAUDE_BIN) { $env:ROOST_CLAUDE_BIN } else { 'claude' }
& $bin @arr
if ($titles) { try { $titles.Stop() } catch { } }
$runInfo['exited'] = $true
[IO.File]::WriteAllText($runFile, ($runInfo | ConvertTo-Json -Compress))
$dim = $PSStyle.Foreground.BrightBlack; $acc = $PSStyle.Foreground.FromRgb(0x5fafff); $rst = $PSStyle.Reset
Write-Host ""
Write-Host "$acc$([char]0x203A)$rst ${dim}claude exited - this is a plain shell now ($rst${acc}roost $Name$rst ${dim}resumes it, $rst${acc}roost close $Name$rst ${dim}removes it)$rst"
