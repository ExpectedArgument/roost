# roost

Keep your [Claude Code](https://claude.com/claude-code) sessions alive. Run many of them side by side in one
terminal, see at a glance which one is working or waiting for you, and get them all back, resumed where they stopped,
after a power cut, a reboot or a dropped SSH connection.

> roost is an independent community project. It is not made by or affiliated with Anthropic.

```
 roost  1:dash  3:api ●  4:docs *  5:infra ?                         ●1 ?1 *1 ○0   14:02
```

| glyph | meaning |
|---|---|
| `●` | working |
| `?` | needs your decision (permission prompt, question) |
| `*` | finished, waiting for your next message |
| `○` | quiet |
| `⏸` | parked: registered, but no window (reopened by `roost restore` or when you pick it) |

## What it does

- **One screen for all sessions.** `roost` opens a dashboard; click a session, or pick it with the arrow keys and
  Enter (Windows: or press its key), to jump to it.
  Only sessions that need you are highlighted in the bottom bar.
- **Sessions survive.** Close the terminal or lose SSH: they keep running (tmux on Linux, [psmux](https://github.com/psmux/psmux) on Windows).
- **Automatic resume.** After a reboot every registered session is reopened with `claude --resume`. Sessions that were
  in the middle of a task get a short "continue where you stopped" prompt; idle ones just reopen. A crash-loop guard stops
  the automatic prompt if the machine keeps rebooting.
- **Remote Control and tab title.** The `RC` column shows whether a session is connected to Remote Control (`on` /
  `off`). roost reads it from the files Claude Code keeps for each running process in `~/.claude/sessions`; this is not
  a documented format, so a future Claude Code version may leave the column empty. The terminal tab is titled
  `🐦 roost`, plus the sessions that wait for you (`🐦 roost  ?1 *2`).
- **No change to your Claude settings.** roost never passes `--model` or effort flags and does not touch `model` or
  `effortLevel`. Only a `hooks` section is added to `~/.claude/settings.json` (backup first). Extra flags pass through:
  `roost new api ~/src/api --model sonnet`.
- **No network, no daemons of its own.** Plain bash / PowerShell, tmux / psmux, `jq`. Nothing is downloaded at install time.

## Linux

Needs `tmux` (3.2+), `jq`, `claude`. Tested on Ubuntu 24.04 with tmux 3.4.

```bash
git clone https://github.com/ExpectedArgument/roost && cd roost/linux
./install.sh              # command + hooks + tmux config
./install.sh --systemd    # also: start at boot, resume after power loss (needs sudo; takes over at the next boot if tmux already runs)
roost new api ~/src/api   # first session (add -c to continue the last chat in that directory)
roost                     # open the dashboard;  Ctrl-b d  detaches;  Ctrl-b w  lists sessions
roost doctor
```

Commands: `roost`, `roost new NAME [DIR] [claude args]`, `roost NAME`, `roost ls`, `roost restore [NAME]`,
`roost close NAME`, `roost forget NAME`, `roost adopt NAME`, `roost doctor`, `roost selftest`.
Remote use: `ssh -t HOST roost`.

Optional hard-stall recovery (hardware watchdog, panic-reboot, NVMe power-state workaround) lives in
[`linux/extras/recovery`](linux/extras/recovery). It is hardware specific and off by default; read it before using it.

## Windows (experimental)

Needs PowerShell 7, `claude`, and [psmux](https://github.com/psmux/psmux) (`winget install psmux --version 3.4.0`,
verify the hash on the release page). The Windows version is **new and only lightly tested**: please report problems.

```powershell
pwsh -File windows\install.ps1
roost selftest ; roost doctor
roost new api C:\src\api
roost                    # dashboard: a click, arrow keys + Enter, or a session's key open / switch;  Ctrl+B d detaches
```

The dashboard (the `dash` window of the `roost` psmux session) redraws in place every 2 seconds. The status bar works like
the Linux one: it lists the dashboard, the current window and the sessions that want something (`3:api ●`), with the
totals and the system drive's usage on the right. Best viewed in Windows Terminal.

- Click a row to open that session; the mouse wheel moves the selection (`ROOST_MOUSE=0` turns the mouse off). Only the
  dashboard takes the mouse; the other windows keep psmux's normal mouse handling.
- `install.ps1` also adds a **roost** profile with the 🐦 icon to the Windows Terminal new-tab menu.

```
 roost   Claude Code sessions                                    ● 1  ? 1  * 1  ○ 0  ⏸ 1    17:29
──────────────────────────────────────────────────────────────────────────────────────────────────

      STATE        NAME   AGE   RC   DIRECTORY
 › 1  ? decide     api    3m    on   ~\src\api
   2  ● working    docs   1m    off  ~\src\docs
   3  * your turn  infra  1h    on   C:\work\infra
   4  ⏸ parked     notes  2d         ~\notes
```

Sessions reopen after you sign in (Startup folder; no admin needed). Windows has no equivalent of a boot service without
sign-in unless you enable auto sign-in yourself.

## Config

| | Linux | Windows |
|---|---|---|
| default claude flags | `~/.config/roost/claude-flags` (`--permission-mode auto`) | `%LOCALAPPDATA%\roost\config\claude-flags` |
| resume prompt | `~/.config/roost/resume-prompt.txt` | `...\config\resume-prompt.txt` |
| state | `~/.local/state/roost` | `%LOCALAPPDATA%\roost` |

Environment: `ROOST_PROJECT_ROOT` (Linux: `roost new NAME` uses `$ROOST_PROJECT_ROOT/NAME` if it exists),
`ROOST_AUTOCONTINUE=0` (never send the automatic prompt), `ROOST_CLAUDE_BIN`, `ROOST_STAGGER`, `ROOST_NET_WAIT`,
`ROOST_MOUSE=0` (Windows: the dashboard ignores the mouse).

On Linux, `~/.config/roost/connectors-allow` lists projects (or `*`) that keep claude.ai connectors enabled; others
start with `ENABLE_CLAUDEAI_MCP_SERVERS=false`, which saves tokens if you do not need them.

## How it works

Claude Code hooks (`SessionStart`, `UserPromptSubmit`, `Stop`, `Notification`, `SessionEnd`, and `PostToolUse` on Linux) call a tiny
script that records each session's id, directory and state in a registry and puts the glyph in the window name. `roost
restore` reads that registry. The hooks print nothing (hook output would be injected into Claude's context) and always exit 0.
Only `/exit` or `/logout` forgets a session; a closed window or a reboot keeps it parked for restore.

## Uninstall

Linux: `linux/uninstall.sh`. Windows: see the bottom of `windows/install.ps1`. Both restore your settings from the backup
or remove only roost's hook entries; your conversations are never touched.

## License

MIT
