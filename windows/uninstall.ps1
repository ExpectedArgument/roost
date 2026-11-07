#requires -Version 7
# Removes roost (Windows), like linux/uninstall.sh. Your Claude conversations are never touched, and config and state in
# %LOCALAPPDATA%\roost are kept (delete them yourself if you like). Preview first:  pwsh -File windows\uninstall.ps1 -DryRun
#   - roost's hook entries in ~\.claude\settings.json (backup first; other hooks and settings stay as they are)
#   - the Startup entry roost-restore.cmd and the `roost` function in your PowerShell profile (backup first)
#   - the Windows Terminal profile fragment and the installed scripts in ~\roost
# Running sessions keep running in psmux; close them first (roost close NAME) if you want them gone.
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format yyyyMMdd-HHmmss
$tag = if ($DryRun) { '[dry-run] ' } else { '' }
function Say([string]$m) { Write-Host "  $tag$m" }
Write-Host ''
Write-Host "  roost uninstall (Windows)$(if ($DryRun) { ': nothing is changed' })"
Write-Host ''

# hooks: drop every hook whose command runs roost-hook, then groups and events left empty
$sp = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path -LiteralPath $sp) {
    $s = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json -AsHashtable
    $removed = 0
    if ($s.Contains('hooks') -and $s['hooks']) {
        foreach ($ev in @($s['hooks'].Keys)) {
            $groups = @()
            foreach ($g in @($s['hooks'][$ev])) {
                $before = @($g['hooks']).Count
                $g['hooks'] = @(@($g['hooks']) | Where-Object { "$($_['command'])" -notmatch 'roost-hook' })
                $removed += $before - $g['hooks'].Count
                if ($g['hooks'].Count) { $groups += , $g }
            }
            if ($groups.Count) { $s['hooks'][$ev] = $groups } else { $s['hooks'].Remove($ev) }
        }
        if (-not $s['hooks'].Count) { $s.Remove('hooks') }
    }
    if ($removed) {
        Say "remove $removed roost hook entr$(if ($removed -eq 1) { 'y' } else { 'ies' }) from settings.json (backup: settings.json.pre-uninstall-roost-$ts)"
        if (-not $DryRun) {
            Copy-Item -LiteralPath $sp -Destination "$sp.pre-uninstall-roost-$ts" -Force
            $s | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $sp -Encoding utf8
        }
    } else { Say 'no roost hooks in settings.json' }
}

# restore at sign-in
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'roost-restore.cmd'
if (Test-Path -LiteralPath $startup) { Say "delete $startup"; if (-not $DryRun) { Remove-Item -LiteralPath $startup -Force } }

# the `roost` function that install.ps1 appended to the profile
if (Test-Path -LiteralPath $PROFILE) {
    $lines = @(Get-Content -LiteralPath $PROFILE)
    $keep = @($lines | Where-Object { $_ -ne '# roost: Claude Code sessions' -and $_ -notmatch '^\s*function roost \{.*\\roost\\roost\.ps1' })
    if ($keep.Count -ne $lines.Count) {
        Say "remove the roost function from $PROFILE (backup: .pre-uninstall-roost-$ts)"
        if (-not $DryRun) {
            Copy-Item -LiteralPath $PROFILE -Destination "$PROFILE.pre-uninstall-roost-$ts" -Force
            Set-Content -LiteralPath $PROFILE -Value $keep -Encoding utf8
        }
    }
}

# Windows Terminal profile and the installed scripts
$wt = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\roost'
if (Test-Path -LiteralPath $wt) { Say "delete the Windows Terminal profile ($wt)"; if (-not $DryRun) { Remove-Item -LiteralPath $wt -Recurse -Force } }
$dst = Join-Path $env:USERPROFILE 'roost'
foreach ($f in 'roost.ps1', 'roost-run.ps1', 'roost-hook.ps1') {
    $p = Join-Path $dst $f
    if (Test-Path -LiteralPath $p) { Say "delete $p"; if (-not $DryRun) { Remove-Item -LiteralPath $p -Force } }
}
if (-not $DryRun -and (Test-Path -LiteralPath $dst) -and -not (Get-ChildItem -LiteralPath $dst -Force)) { Remove-Item -LiteralPath $dst -Force }

Write-Host ''
Write-Host "  Kept: $(Join-Path $env:LOCALAPPDATA 'roost') (config, registry; delete it if you like) and your conversations."
Write-Host '  Sessions still running in psmux keep running: psmux kill-session -t roost ends them.'
Write-Host ''
