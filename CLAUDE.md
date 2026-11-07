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
- **Windows dashboard, end to end:** psmux commands run from *inside* a pane always reach the **default** psmux server,
  even when that pane belongs to a `psmux -L <name>` server. A dashboard tested on a `-L` server would therefore act on
  the user's real sessions. Test it instead in a separate session on the default server:
  - set `ROOST_PSMUX_SESSION=roosttest`, a temp `ROOST_HOME`, `ROOST_DRY=1` and a temp `CLAUDE_CONFIG_DIR`;
  - inject clicks the way psmux delivers real ones, as typed text: `psmux send-keys -t roosttest:dash Escape`, then
    `psmux send-keys -t roosttest:dash -l '[<0;X;YM'` (SGR, 1-based). Read the result with
    `psmux display-message -p -t roosttest '#{window_name}'`;
  - don't put the ESC inside a single `send-keys -l`: that takes another path (conhost turns it into a `MOUSE_EVENT`
    record) and hides bugs in the text path;
  - `ROOST_DASH_LOG=<file>` logs every raw input record. Rows are sorted by name, not by the order you created them;
  - never point a fake `run/NAME.run.json` at a real process and then run `close`, because `close` does
    `taskkill /T /F` on that pid.
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
- psmux window ids (`@N`) are **per psmux session**, not per server. Always target `"<session>:@N"`. `Get-WinId`
  returns that form, and the hook renames with it. A bare `@N` can select, or kill, a window of another psmux session.
- Dashboard input:
  - `Show-Dash` reads console input records itself through the embedded C# class `RoostDashInput`
    (`$DashInputSrc`), because `[Console]::KeyAvailable` silently drops mouse records.
  - It asks for the mouse twice: `ENABLE_MOUSE_INPUT` (quick edit and VT input off) and DECSET 1000/1006. psmux then
    forwards clicks to that pane only (checkable as `#{mouse_any_flag}`). No global `MouseDown1Pane` binding is used,
    because that would replace psmux's click handling in every pane.
  - psmux types keys and mouse reports into the pane as **VT text**. They arrive as key-down records with `vk=0`
    (`ESC [ A` for Up, `ESC [ < 0;11;6 M` for a click); only the key-up records carry the real vk. Real `MOUSE_EVENT`
    records can arrive too.
  - The reader therefore parses escape sequences itself (`Escape` / `Csi`). A character inside an escape sequence
    must never count as a key: the digits of a click's coordinates would "press" 1-9 and open sessions.
  - A click maps to a row through `$RowY0` (the screen line of the first row) and that frame's `$top` / `$end`.
  - `ROOST_MOUSE=0` only stops asking for the mouse. Keys still go through the reader, because plain
    `[Console]::ReadKey` would see `ESC [ A` as Esc, `[`, `a`.
- RC column (`Get-RcIndex`):
  - It reads Claude Code's per-process files `~/.claude/sessions/<pid>.json` (`CLAUDE_CONFIG_DIR` moves `~/.claude`).
    This is an internal, undocumented format.
  - A file counts only while `pid` is alive with a matching `procStart` (a FILETIME, same as `run.json`).
  - It matches the registry `session_id` to the file's `sessionId`. `bridgeSessionId` non-empty means connected.
  - A session handed to a background job has `parkedJobId`, which points to the job's file (`jobId`).
  - It must fail soft: no file or field means an empty cell.
- Tab title: `Set-PcTheme` turns on psmux `set-titles`, the dash pushes `set-titles-string` (`🐦 roost` plus `?`/`*`
  counts) and `Invoke-Attach` restores the previous title after a detach. `install.ps1` adds a Windows Terminal profile
  as a JSON fragment (`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\roost\roost.json`, emoji icon).
- Dashboard clicks, the RC column and the tab title are **Windows only so far**. The Linux port has its own click
  handling (`roost click`) but no RC column or title yet.
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
