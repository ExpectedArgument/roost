# Runs inside a psmux window opened by `roost`: starts claude for session NAME.
param([Parameter(Mandatory)][string]$Name)

$csHome = if ($env:ROOST_HOME) { $env:ROOST_HOME } else { Join-Path $env:LOCALAPPDATA 'roost' }
$env:ROOST_NAME = $Name   # the hooks only act when this is set

$argsFile = Join-Path $csHome "run\$Name.args.json"
$a = [pscustomobject]@{ sid = ''; prompt = ''; extra = @() }
if (Test-Path -LiteralPath $argsFile) { $a = Get-Content -LiteralPath $argsFile -Raw -Encoding utf8 | ConvertFrom-Json }
$extra = @($a.extra | Where-Object { $_ })

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

# lets `roost` know this window is open (used to tell open sessions from parked ones)
$me = Get-Process -Id $PID
$runInfo = @{ pid = $PID; start = $me.StartTime.ToFileTimeUtc() } | ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $csHome "run\$Name.run.json"), $runInfo)

# Outside psmux the tab title shows the session state: ● working  ? needs your decision  * waiting for your message  ○ quiet.
# A background runspace polls the registry and writes the terminal-title escape sequence. EXPERIMENTAL:
# disable with  $env:ROOST_TITLES = '0'  (then the tab simply keeps claude's own title).
if ($env:TMUX) {
    $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'   # inside psmux the hook puts the state glyph in the window name
} elseif ($env:ROOST_TITLES -ne '0') {
    $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'   # otherwise claude overwrites our title
    try {
        $regPath = Join-Path $csHome "sessions\$Name.json"
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
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
        [void]$ps.BeginInvoke()
    } catch { }
}

$arr = $cargs.ToArray()
& claude @arr
$dim = $PSStyle.Foreground.BrightBlack; $acc = $PSStyle.Foreground.FromRgb(0x5fafff); $rst = $PSStyle.Reset
Write-Host ""
Write-Host "$acc$([char]0x203A)$rst ${dim}claude exited - this is a plain shell now ($rst${acc}roost close $Name$rst ${dim}removes the session)$rst"
