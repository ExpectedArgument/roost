# windows/ (PowerShell 7 + psmux)

Port-specific notes. Shared design (hook events, state values, lifecycle, invariants) is in the root `CLAUDE.md`.

## Checking changes

- **Selftest:** `pwsh -NoProfile -File windows\roost.ps1 selftest`.
  - It runs the hook through a full start → busy → attention → idle → end cycle and runs `new` as a dry run.
  - It works in a temp `ROOST_HOME` with `ROOST_DRY=1`, so no windows open and the real registry is untouched.
  - It resolves sibling scripts through `$PSScriptRoot`, so run from the repo it tests the repo copies.
- **Dry run:** set `ROOST_DRY=1` and `roost new …` / `restore` print the psmux command instead of running it.
  `Start-Tab` still writes `run/NAME.args.json` before the dry-run check, so pair it with a temp `ROOST_HOME`, as
  selftest does.
- **psmux probe:** `windows\probe-psmux.ps1` checks which psmux features roost can rely on. It uses a throw-away
  session called `roost-probe`.
- **Dashboard, end to end:** psmux commands run from *inside* a pane always reach the **default** psmux server,
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

## Design

- All sessions are windows of one psmux session. Its name comes from `ROOST_PSMUX_SESSION` and defaults to `roost`.
  Window `dash` runs `roost.ps1 dash`, an in-place-redrawing TUI that also pushes the `status-right` counts.
- psmux has no per-window user options. The hook therefore puts the glyph into the **window name** (`"● api"`), and
  the status-bar format in `Set-PcTheme` parses the name's first character. Window lookup (`Get-WinId`) matches
  `^(\S\s)?NAME$`, which is why session names must match `^[A-Za-z0-9._-]+$` (no spaces).
- The dash also keeps those glyphs in step with the registry (`Sync-WinNames`). Hooks of a session that was moved to a
  background job run outside psmux and cannot rename the window.
- The status bar mirrors `linux/tmux.conf`: it shows only the dash window, the current window and the busy, attention
  and waiting windows, as `3:api ●`.
  - Inspect a window's rendered piece with `psmux display-message -p -t S:N '#{E:window-status-format}'`.
  - Status strings go through strftime, so a literal `%` must be written `%%`.
- In PowerShell strings write `${Dot}?`, not `$Dot?`. `?` is a valid variable-name character, so `"$Dot?"` expands
  the empty variable `Dot?`.
- psmux window ids (`@N`) are **per psmux session**, not per server. Always target `"<session>:@N"`. `Get-WinId`
  returns that form, and the hook renames with it. A bare `@N` can select, or kill, a window of another psmux session.
- The display state is stored in the registry `display` field and copied into the window name.
- Windows does **not** register `PostToolUse`, so `?` clears on the next Stop or UserPromptSubmit, not right after
  the prompt is answered.
- `Start-Tab` writes the resume id, prompt and extra args to `run/NAME.args.json` and opens a window running
  `roost-run.ps1 NAME`, which builds the `claude` argv from that file. This avoids quoting args through psmux.
- Open vs parked: `roost-run.ps1` writes `run/NAME.run.json` holding its PID and process start time. `Test-Alive`
  compares both, so a reused PID does not count as open.
- The default resume prompt is the repo file `windows/resume-prompt.txt`. `install.ps1` copies it to
  `config\resume-prompt.txt` only if that file is missing, so edits to the repo copy don't reach existing installs.
- State and config live in `%LOCALAPPDATA%\roost`, overridable with `ROOST_HOME`.

## Dashboard input

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

## RC column and tab title

The shared rules are in the root `CLAUDE.md`. Windows specifics:

- `Get-RcIndex` builds the RC index. `procStart` is a FILETIME, the same value `run.json` stores.
- `Set-PcTheme` turns on psmux `set-titles`, the dash pushes `set-titles-string` (`Format-Title`) and `Invoke-Attach`
  restores the previous title after a detach.
- Outside psmux, `roost-run.ps1` sets the title from a background runspace (`ROOST_TITLES=0` disables it).
- `install.ps1` adds a Windows Terminal profile as a JSON fragment
  (`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\roost\roost.json`, emoji icon).

The Linux port clicks through a tmux mouse binding (`roost click`) instead of this input reader.

## Restore at sign-in

A `roost-restore.cmd` in the Startup folder runs `roost.ps1 restore -Boot`, which:
1. waits for `api.anthropic.com` (`Wait-Network`),
2. runs the crash-loop guard (3 boots in 30 min means no auto-continue prompt, using `boots.log`),
3. staggers launches by `ROOST_STAGGER` seconds.
