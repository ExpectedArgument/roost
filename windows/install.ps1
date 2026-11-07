#requires -Version 7
# Installs roost for Windows: copies the scripts to ~\roost, registers the Claude Code hooks (with a backup of
# settings.json), adds a restore-at-logon entry to the Startup folder and a `roost` function to your PowerShell profile.
# Nothing is downloaded. Undo: see UNINSTALL at the bottom of this file.
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dst = Join-Path $env:USERPROFILE 'roost'

$color = ($PSStyle.OutputRendering -ne 'PlainText') -and -not [Console]::IsOutputRedirected
function Paint([string]$t, [string]$sgr) { if ($color) { "$([char]27)[${sgr}m$t$([char]27)[0m" } else { $t } }
function Step([string]$m) { Write-Host ('  ' + (Paint ([string][char]0x2713) '38;5;40') + ' ' + $m) }
function Note([string]$m) { Write-Host ('    ' + (Paint $m '38;5;245')) }
Write-Host ''
Write-Host ('  ' + (Paint ' roost ' '1;48;5;39;38;5;16') + '  ' + (Paint 'install (Windows)' '38;5;245'))
Write-Host ''

New-Item -ItemType Directory -Force -Path $dst | Out-Null
foreach ($f in 'roost.ps1', 'roost-run.ps1', 'roost-hook.ps1') { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $dst -Force }
Step "scripts copied to $dst"

# config (kept if it already exists)
$cfg = Join-Path $env:LOCALAPPDATA 'roost\config'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
$pf = Join-Path $cfg 'resume-prompt.txt'
if (-not (Test-Path -LiteralPath $pf)) { Copy-Item -LiteralPath (Join-Path $src 'resume-prompt.txt') -Destination $pf }
$ff = Join-Path $cfg 'claude-flags'
if (-not (Test-Path -LiteralPath $ff)) { Set-Content -LiteralPath $ff -Value '--permission-mode auto' }
Step "config in $cfg (existing files kept)"

# hooks in ~/.claude/settings.json (existing settings are kept; backup first)
$sp = Join-Path $env:USERPROFILE '.claude\settings.json'
New-Item -ItemType Directory -Force -Path (Split-Path $sp) | Out-Null
$s = @{}
if (Test-Path -LiteralPath $sp) {
    $bk = $sp + '.pre-roost-' + (Get-Date -Format yyyyMMdd-HHmmss)
    Copy-Item -LiteralPath $sp -Destination $bk -Force
    Step 'settings.json backed up'
    Note $bk
    $s = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json -AsHashtable
}
if (-not $s.ContainsKey('hooks')) { $s['hooks'] = @{} }
$hk = ($dst -replace '\\', '/') + '/roost-hook.ps1'
$events = [ordered]@{ SessionStart = 'start'; UserPromptSubmit = 'busy'; Stop = 'idle'; Notification = 'attention'; SessionEnd = 'end' }
foreach ($ev in $events.Keys) {
    $cmd = "pwsh -NoProfile -File $hk $($events[$ev])"
    $list = @()
    if ($s['hooks'].ContainsKey($ev)) { $list = @($s['hooks'][$ev]) }
    $has = $false
    foreach ($g in $list) { foreach ($h in @($g.hooks)) { if ("$($h.command)" -match 'roost-hook\.ps1') { $has = $true } } }
    if (-not $has) {
        $timeout = if ($ev -eq 'SessionEnd') { 3 } else { 10 }
        $list += @{ hooks = @(@{ type = 'command'; command = $cmd; timeout = $timeout }) }
    }
    $s['hooks'][$ev] = $list
}
$s | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $sp -Encoding utf8
Step 'Claude Code hooks registered'

# reopen sessions after logon (Startup folder: no admin rights needed)
$startup = [Environment]::GetFolderPath('Startup')
$line = 'start "" /min pwsh -NoProfile -WindowStyle Hidden -File "' + (Join-Path $dst 'roost.ps1') + '" restore -Boot'
Set-Content -LiteralPath (Join-Path $startup 'roost-restore.cmd') -Value $line -Encoding ascii
Step 'sessions reopen after you sign in (Startup folder)'

# Windows Terminal: a "roost" profile with an icon in the new-tab menu. A JSON fragment, so Terminal's own settings.json
# is not touched. Detaching (Ctrl+B d) closes that tab; the sessions keep running.
$wtRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal'
if ((Test-Path -LiteralPath $wtRoot) -or (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    $wtDir = Join-Path $wtRoot 'Fragments\roost'
    New-Item -ItemType Directory -Force -Path $wtDir | Out-Null
    $frag = [ordered]@{
        profiles = @([ordered]@{
                guid              = '{6f1c3b2a-8d4e-4f7a-9b2c-5e0d1a7f3c48}'
                name              = 'roost'
                commandline       = 'pwsh.exe -NoLogo -NoProfile -File "' + (Join-Path $dst 'roost.ps1') + '"'
                icon              = [char]::ConvertFromUtf32(0x1F426)
                startingDirectory = '%USERPROFILE%'
                tabTitle          = 'roost'
            })
    }
    $frag | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $wtDir 'roost.json') -Encoding utf8
    Step 'Windows Terminal profile "roost" added (new-tab menu)'
}

# `roost` command in PowerShell
if (-not (Test-Path -LiteralPath $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
if (-not (Select-String -LiteralPath $PROFILE -Pattern 'roost\roost.ps1' -SimpleMatch -Quiet)) {
    Add-Content -LiteralPath $PROFILE -Value "`n# roost: Claude Code sessions`nfunction roost { & `"`$env:USERPROFILE\roost\roost.ps1`" @args }"
    Step 'roost command added to your PowerShell profile'
} else {
    Step 'roost command already in your PowerShell profile'
}
if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) {
    Write-Host ('  ' + (Paint '!' '1;38;5;214') + ' ' + (Paint 'psmux not found. Install it first:  winget install psmux --version 3.4.0' '38;5;214'))
}
Write-Host ''
Write-Host ('  ' + (Paint 'Done.' '1') + ' Open a NEW PowerShell window, then run:')
Write-Host ('      ' + (Paint 'roost selftest' '38;5;39') + '   ' + (Paint 'roost doctor' '38;5;39') + '   ' + (Paint 'roost new NAME DIR' '38;5;39'))
Write-Host ''

# UNINSTALL: delete %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\roost-restore.cmd, delete the `roost` function
# from your profile, delete ~\roost, %LOCALAPPDATA%\roost and %LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\roost,
# and copy the newest ~\.claude\settings.json.pre-roost-* back over ~\.claude\settings.json.
