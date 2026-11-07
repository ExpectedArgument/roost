# Read-only probe: checks which psmux features roost can rely on. Uses a throw-away session "roost-probe", removed at the end.
function Run($label, [scriptblock]$b) {
    Write-Host "== $label"
    try { $o = & $b 2>&1 | Out-String; Write-Host ($o.TrimEnd()) } catch { Write-Host "ERROR: $($_.Exception.Message)" }
}
psmux kill-session -t roost-probe 2>$null | Out-Null
Run 'new-session -d' { psmux new-session -d -s roost-probe -n w0; "exit=$LASTEXITCODE" }
Run 'new-window with dir + command' {
    psmux new-window -d -t roost-probe: -n w1 -c "$env:USERPROFILE" -- pwsh -NoLogo -NoExit -Command "Set-Content $env:TEMP\roost-probe-pane.txt (`$env:TMUX_PANE + '|' + `$env:TMUX)"
    "exit=$LASTEXITCODE"
}
Start-Sleep 3
Run 'pane env (TMUX_PANE|TMUX)' { Get-Content $env:TEMP\roost-probe-pane.txt }
Run 'list-windows format' { psmux list-windows -t roost-probe -F '#{window_index}|#{window_id}|#{pane_id}|#{window_name}|#{pane_current_path}' }
Run 'rename-window by name' { psmux rename-window -t roost-probe:w1 'busy w1'; "exit=$LASTEXITCODE"; psmux list-windows -t roost-probe -F '#{window_index}|#{window_name}' }
Run 'rename-window by pane id' {
    $p = (Get-Content $env:TEMP\roost-probe-pane.txt).Split('|')[0]
    psmux rename-window -t $p 'by-pane'; "exit=$LASTEXITCODE (target $p)"; psmux list-windows -t roost-probe -F '#{window_index}|#{window_name}'
}
Run 'per-window user option' {
    psmux set-option -w -t roost-probe:0 '@cs_state' busy
    psmux set-option -w -t roost-probe:1 '@cs_state' idle
    'w0=' + (psmux display-message -p -t roost-probe:0 '#{@cs_state}') + ' w1=' + (psmux display-message -p -t roost-probe:1 '#{@cs_state}')
}
Run 'status-bar shell command #()' { psmux display-message -p -t roost-probe 'x[#(cmd /c echo hi)]x' }
Run 'select-window by id' { psmux select-window -t roost-probe:0; "exit=$LASTEXITCODE" }
Run 'cleanup' { psmux kill-session -t roost-probe; Remove-Item $env:TEMP\roost-probe-pane.txt -ErrorAction SilentlyContinue; psmux ls }
