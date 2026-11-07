# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

roost keeps Claude Code sessions alive in a terminal multiplexer, shows each one's state (`●` working, `?` needs a
decision, `*` your turn, `○` quiet, `⏸` parked) and reopens them with `claude --resume` after a reboot. It is plain
shell, with no build step, no dependencies to download, no network and no daemon of its own.

`linux/` (bash, tmux 3.2+, jq) and `windows/` (PowerShell 7, [psmux](https://github.com/psmux/psmux)) are **two
independent ports of the same design. They share no code.** Mirror a behaviour change in both unless it is
platform-specific. The Windows port is newer and marked experimental.

## Checking changes

There is no build, lint or test framework. Don't invent one. What exists:

- **Windows:** `pwsh -NoProfile -File windows\roost.ps1 selftest`.
  - It runs the hook through a full start → busy → attention → idle → end cycle and runs `new` as a dry run.
  - It works in a temp `ROOST_HOME` with `ROOST_DRY=1`, so no windows open and the real registry is untouched.
  - It resolves sibling scripts through `$PSScriptRoot`, so run from the repo it tests the repo copies.
- **Windows dry run:** set `ROOST_DRY=1` and `roost new …` / `restore` print the psmux command instead of running it.
  `Start-Tab` still writes `run/NAME.args.json` before the dry-run check, so pair it with a temp `ROOST_HOME`, as
  selftest does.
- **Windows psmux probe:** `windows\probe-psmux.ps1` checks which psmux features roost can rely on. It uses a throw-away
  session called `roost-probe`.
- **Linux:** `roost doctor`. Useful knobs:
  - `ROOST_TMUX_SOCKET`: a separate tmux server.
  - `ROOST_STATE_DIR` / `ROOST_CONF_DIR`: isolated state and config.
  - `ROOST_HOOK_DEBUG=1`: logs to `$STATE_DIR/hook.log`.
  - `ROOST_UPTIME_OVERRIDE`: fakes a fresh boot for the crash-loop guard.
  - `ROOST_NO_ATTACH=1`: no attach.

**Installed copies are separate from the repo.** Edits here take effect only after reinstalling:
- Windows: `pwsh -File windows\install.ps1` copies the scripts to `~\roost`.
- Linux: `linux/install.sh` writes `~/.local/bin/roost`, `~/.claude/hooks/roost-hook.sh` and a
  `@ROOST_BIN@`-substituted `~/.config/roost/tmux.conf`.

Both installers back up `~/.claude/settings.json` to `settings.json.pre-roost-<timestamp>` and add hooks idempotently.
They detect an existing entry by matching `roost-hook` in the command.

## Architecture

### Data flow

1. Claude Code hooks call the hook script with an event argument and the hook JSON on stdin:
   - `SessionStart` → `start`
   - `UserPromptSubmit` → `busy`
   - `Stop` → `idle`
   - `Notification` → `attention`
   - `SessionEnd` → `end`
   - Linux only: `PostToolUse` → `resume`
2. The hook writes the registry entry `sessions/NAME.json` atomically (tmp file, then move).
   - Both ports store name, cwd, session_id, transcript, `state` and `updated`.
   - Windows also stores `display`.
   - Linux also stores `permission_mode` and `connectors`. It keeps the display state only in the tmux window option
     `@roost_state`, not in the file.
3. The main script (`linux/bin/roost` / `windows/roost.ps1`) reads the registry for `ls`, the dashboard and `restore`.

### The two state values

- **`state`** is `busy` or `idle`. It decides whether `restore` appends the auto-continue prompt
  (`resume-prompt.txt`), which happens only for sessions that were busy.
- **The display state** is `busy`, `attention`, `waiting` or `idle`, and drives the UI glyph. It is stored in the
  registry `display` field on Windows (and copied into the window name) and in `@roost_state` on Linux.
- After a `compact` SessionStart the previous state is kept.
- A permission or elicitation prompt sets the display state to `attention` and leaves `state` unchanged.

### Session lifecycle

Only `SessionEnd` with reason `prompt_input_exit` or `logout` (`/exit`, `/logout`) deletes an entry. A closed window, a
kill or a reboot keeps it, so the session is "parked" and comes back with `roost restore`.

### Hook invariants (both ports)

- Print nothing on stdout. SessionStart and UserPromptSubmit stdout is injected into the model's context.
- Always exit 0 and stay fast.
- Do nothing unless the session is managed by roost:
  - Windows: env `ROOST_NAME`, set by `roost-run.ps1`.
  - Linux: tmux window option `@roost_managed=1`, set by `launch`/`adopt`.

### Settings roost must not touch

roost never passes `--model` or effort flags. Default claude flags come from `config/claude-flags`, which defaults to
`--permission-mode auto`. An explicit `--permission-mode` in the extra args replaces the default.

### Windows specifics (`windows/`)

- All sessions are windows of one psmux session. Its name comes from `ROOST_PSMUX_SESSION` and defaults to `roost`.
  Window `dash` runs `roost.ps1 dash`, an in-place-redrawing TUI that also pushes the `status-right` counts.
- psmux has no per-window user options. The hook therefore puts the glyph into the **window name** (`"● api"`), and
  the status-bar format in `Set-PcTheme` parses the name's first character. Window lookup (`Get-WinId`) matches
  `^(\S\s)?NAME$`, which is why session names must match `^[A-Za-z0-9._-]+$` (no spaces).
- `Start-Tab` writes the resume id, prompt and extra args to `run/NAME.args.json` and opens a window running
  `roost-run.ps1 NAME`, which builds the `claude` argv from that file. This avoids quoting args through psmux.
- Open vs parked: `roost-run.ps1` writes `run/NAME.run.json` holding its PID and process start time. `Test-Alive`
  compares both, so a reused PID does not count as open.
- Outside psmux, `roost-run.ps1` sets the terminal title from a background runspace. Set `ROOST_TITLES=0` to disable
  it.
- Restore at sign-in: a `roost-restore.cmd` in the Startup folder runs `roost.ps1 restore -Boot`, which:
  1. waits for `api.anthropic.com` (`Wait-Network`),
  2. runs the crash-loop guard (3 boots in 30 min means no auto-continue prompt, using `boots.log`),
  3. staggers launches by `ROOST_STAGGER` seconds.
- State and config live in `%LOCALAPPDATA%\roost`, overridable with `ROOST_HOME`.
- Windows does **not** register `PostToolUse`, even though the README lists it among the hooks. So `?` clears on the
  next Stop or UserPromptSubmit, not right after the prompt is answered.

### Linux specifics (`linux/`)

- One tmux session (`ROOST_TMUX_SESSION`, default `roost`).
- Per-window options identify and track sessions: `@roost_managed`, `@roost_name`, `@roost_state` and `@roost_conn`.
  The `tmux.conf` status format reads `@roost_state` directly.
- Window `dash` runs `watch roost ls --color`. A mouse binding in `tmux.conf` calls `roost click <line>` to jump to a
  session.
- Open vs parked: a window exists and `pane_current_command` is `claude`. A window left with a plain shell shows as
  `SHELL`, and restore recreates it.
- The registry also stores `permission_mode` and `connectors`, and restore reapplies them. Sessions not listed in
  `connectors-allow` start with `ENABLE_CLAUDEAI_MCP_SERVERS=false`.
- `restore` holds a `flock` on fd 9. `tm()` closes fd 9 (`9>&-`) so a tmux server started from inside restore does
  not inherit the lock forever.
- `--systemd` installs `roost-tmux.service` and `roost-restore.service` from the `systemd/*.in` templates (substituting
  `@USER@`, `@UID@`, `@HOME@` and `@ROOST_BIN@`) and enables linger.
- `linux/extras/recovery` holds hardware-specific watchdog, panic and NVMe settings. They are not installed by default.
  Never open `/dev/watchdog*` from a script, because opening it arms the timer.
