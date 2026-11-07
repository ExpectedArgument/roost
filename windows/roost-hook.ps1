# Claude Code hook for roost (Windows). Keeps the session registry up to date.
# RULES: silent on stdout (SessionStart / UserPromptSubmit stdout is injected into the model context),
#        always exit 0, no-op unless the session was started by `roost` (env ROOST_NAME).
# Usage (from settings.json hooks):  pwsh -NoProfile -File roost-hook.ps1 start|busy|idle|attention|resume|end   (JSON on stdin)
# `resume` comes from PostToolUse (async, behind a bash check for sessions\NAME.ask): a "?" prompt was answered.
param([string]$Ev)

$ErrorActionPreference = 'SilentlyContinue'
try {
    $name = $env:ROOST_NAME
    if (-not $name) { exit 0 }
    $csHome = if ($env:ROOST_HOME) { $env:ROOST_HOME } else { Join-Path $env:LOCALAPPDATA 'roost' }
    $dir = Join-Path $csHome 'sessions'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir "$name.json"
    $ask = Join-Path $dir "$name.ask"   # exists while the session shows "?"; lets the PostToolUse check skip pwsh otherwise

    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    $raw = [Console]::In.ReadToEnd()
    $j = if ($raw -and $raw.Trim()) { $raw | ConvertFrom-Json } else { [pscustomobject]@{} }

    if ($Ev -eq 'end') {
        # Only an explicit user exit forgets the session. Window close / reboot / kill keep it for `roost restore`.
        if ($j.reason -in 'prompt_input_exit', 'logout') { Remove-Item -LiteralPath $f, $ask -Force }
        exit 0
    }
    if ($Ev -eq 'resume' -and -not (Test-Path -LiteralPath $ask)) { exit 0 }

    $old = $null
    if (Test-Path -LiteralPath $f) { $old = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json }
    $oldState = if ($old -and $old.state) { [string]$old.state } else { 'idle' }
    $oldDisp = if ($old -and $old.display) { [string]$old.display } else { 'idle' }

    # state   = busy|idle (decides whether a restored session gets the auto "continue" prompt)
    # display = busy|attention(?)|waiting(*)|idle
    switch ($Ev) {
        'start' {
            if ($j.source -eq 'compact' -and $old) { $st = $oldState; $ds = $oldDisp } else { $st = 'idle'; $ds = 'idle' }
        }
        'busy' { $st = 'busy'; $ds = 'busy' }
        'idle' { $st = 'idle'; $ds = 'waiting' }
        'attention' {
            $nt = [string]$j.notification_type
            if (-not $nt) {
                if ([string]$j.message -match 'waiting for (your )?input') { $nt = 'idle_prompt' } else { $nt = 'permission_prompt' }
            }
            switch ($nt) {
                { $_ -in 'permission_prompt', 'elicitation_dialog' } { $st = $oldState; $ds = 'attention' }
                'idle_prompt' { $st = 'idle'; $ds = 'waiting' }
                default { $st = $oldState; $ds = $oldDisp }
            }
        }
        'resume' {
            # PostToolUse: a tool ran, so a "?" prompt was answered and the session is working again
            if ($oldDisp -ne 'attention') { Remove-Item -LiteralPath $ask -Force; exit 0 }
            $st = 'busy'; $ds = 'busy'
        }
        default { exit 0 }
    }

    $sid = if ($j.session_id) { [string]$j.session_id } elseif ($old) { [string]$old.session_id } else { '' }
    if (-not $sid) { exit 0 }
    $cwd = if ($j.cwd) { [string]$j.cwd } elseif ($old) { [string]$old.cwd } else { (Get-Location).Path }
    $tp = if ($j.transcript_path) { [string]$j.transcript_path } elseif ($old) { [string]$old.transcript } else { '' }
    # not every event carries permission_mode: keep the last one seen (restore reapplies it)
    $pm = if ($j.permission_mode) { [string]$j.permission_mode } elseif ($old -and $old.permission_mode) { [string]$old.permission_mode } else { '' }

    $obj = [ordered]@{
        name            = $name
        cwd             = $cwd
        session_id      = $sid
        transcript      = $tp
        state           = $st
        display         = $ds
        permission_mode = $pm
        connectors      = ($env:ROOST_CONN -eq '1')   # set by roost-run.ps1 when claude.ai connectors are on
        updated         = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    # an async resume can race the next Stop: write only while the "?" flag still exists (Stop removes it)
    if ($Ev -eq 'resume' -and -not (Test-Path -LiteralPath $ask)) { exit 0 }
    $tmp = "$f.tmp"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $f -Force
    if ($ds -eq 'attention') { [IO.File]::WriteAllText($ask, '') } else { Remove-Item -LiteralPath $ask -Force }

    # inside psmux: show the state as a glyph in the window name ("* NAME"), which is what the status bar lists
    if ($env:TMUX -and (Get-Command psmux -ErrorAction SilentlyContinue)) {
        $ps = if ($env:ROOST_PSMUX_SESSION) { $env:ROOST_PSMUX_SESSION } else { 'roost' }
        $g = switch ($ds) { 'busy' { [string][char]0x25CF } 'attention' { '?' } 'waiting' { '*' } default { [string][char]0x25CB } }
        $rx = '^(\S\s)?' + [regex]::Escape($name) + '$'
        foreach ($l in @(& psmux list-windows -t $ps -F '#{window_id}|#{window_name}' 2>$null)) {
            $w = "$l".Split('|', 2)
            if ($w.Count -eq 2 -and $w[1] -match $rx) {
                & psmux rename-window -t "${ps}:$($w[0])" "$g $name" 2>$null | Out-Null   # window ids are per psmux session
                if ($LASTEXITCODE -ne 0) { & psmux rename-window -t "${ps}:$($w[1])" "$g $name" 2>$null | Out-Null }
                break
            }
        }
    }
} catch { }
exit 0
