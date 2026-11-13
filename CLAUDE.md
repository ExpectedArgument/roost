# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

roost keeps Claude Code sessions alive in a terminal multiplexer, shows each one's state (`●` working, `?` needs a
decision, `*` your turn, `○` quiet, `◌` parked) and reopens them with `claude --resume` after a reboot. It is plain
shell, with no build step, no dependencies to download, no network and no daemon of its own.

`linux/` (bash, tmux 3.2+, jq) and `windows/` (PowerShell 7, [psmux](https://github.com/psmux/psmux)) are **two
independent ports of the same design. They share no code.** Mirror a behaviour change in both unless it is
platform-specific. The Windows port is newer and marked experimental.

Port-specific detail lives in `linux/CLAUDE.md` and `windows/CLAUDE.md`. They load only when you read files in that
directory, so open the one for the port you are changing before you test it.

## Checking changes

There is no build, lint or test framework. Don't invent one. What exists:

- **Windows:** `pwsh -NoProfile -File windows\roost.ps1 selftest`. It uses a temp `ROOST_HOME` and `ROOST_DRY=1`, opens
  no windows, and runs `roost-run.ps1` with a fake claude through `ROOST_CLAUDE_BIN`. `windows/CLAUDE.md` describes a
  psmux end-to-end recipe.
- **Linux:** `linux/bin/roost selftest` (own tmux socket, state and a fake `claude`; touches nothing real), plus
  `roost doctor` for the installed setup. Read the safety notes in `linux/CLAUDE.md` before running the hook by hand.

Three hazards when testing by hand (details in `windows/CLAUDE.md`):
- psmux commands run from *inside* a pane always reach the **default** psmux server, so a dashboard tested on a
  `psmux -L <name>` server acts on the user's real sessions.
- `roost close` does `taskkill /T /F` on the pid in `run/NAME.run.json`. Never point a fake one at a real process.
- psmux's status bar renderer prints some formats raw that `display-message` expands fine. Check bar changes with
  `windows\probe-statusbar.ps1`, which shows the bar as a terminal really draws it.

**Installed copies are separate from the repo.** Edits here take effect only after reinstalling:
- Windows: `pwsh -File windows\install.ps1` copies the scripts to `~\roost`.
- Linux: `linux/install.sh` writes `~/.local/bin/roost`, `~/.claude/hooks/roost-hook.sh` and a
  `@ROOST_BIN@`-substituted `~/.config/roost/tmux.conf`.

Both installers add hooks idempotently. They detect an existing entry by matching `roost-hook` in the command, and they
touch `~/.claude/settings.json` only when a hook is missing, after backing it up to `settings.json.pre-roost-<timestamp>`.

## Architecture

### Data flow

1. Claude Code hooks call the hook script with an event argument and the hook JSON on stdin:
   - `SessionStart` → `start`
   - `UserPromptSubmit` → `busy`
   - `Stop` → `idle`
   - `Notification` → `attention`
   - `SessionEnd` → `end`
   - `PostToolUse` → `resume`. It clears `?` once a prompt is answered and does nothing otherwise. Windows runs it
     async, behind a cheap bash check, because pwsh is slow to start.
2. The hook writes the registry entry `sessions/NAME.json` atomically (tmp file, then move).
   - Both ports store name, cwd, session_id, transcript, `state`, `permission_mode`, `connectors` and `updated`.
     `restore` reapplies the permission mode (never `bypassPermissions`) and the connectors.
   - Not every event carries `permission_mode`, so both ports keep the last value seen (`auto` before any).
   - Windows also stores `display`. Linux keeps the display state only in the tmux window option `@roost_state`.
3. The main script (`linux/bin/roost` / `windows/roost.ps1`) reads the registry for `ls`, the dashboard and `restore`.
   - A window whose claude quit, leaving a plain shell, shows as `SHELL` (Linux) or `× exited` (Windows).
   - `restore` reopens it, like a parked session.

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

### Remote Control column and tab title (both ports)

- `ls` and the Windows dashboard show an RC column: `on`, `off`, or empty for a parked session. It reads Claude Code's
  per-process files `~/.claude/sessions/<pid>.json` (`CLAUDE_CONFIG_DIR` moves `~/.claude`). That is an internal,
  undocumented format, so it must fail soft: no file or field means an empty cell.
  - A file counts only while its `pid` is alive and the process start time equals `procStart`, so a reused pid does not
    match. Windows compares a FILETIME, Linux field 22 of `/proc/PID/stat`.
  - It matches the registry `session_id` to the file's `sessionId`. A non-empty `bridgeSessionId` means connected.
  - A session handed to a background job has `parkedJobId`, which points to the job's file (`jobId`). The job's process
    holds the connection.
- The terminal tab title is `🐦 roost`, plus `?N` / `*N` for the sessions that need you or wait for you. Windows pushes
  it from the dash. Linux has tmux call `roost title` through `set-titles-string`.

### Model, effort and advisor columns (both ports)

- `roost ls` and the Windows dashboard show MODEL, EFFORT and ADVISOR per session (`opus 5.5`, `max`, `opus 5.5`).
- Hooks are no source for these: `model` arrives only on some SessionStarts, `effort` only on tool-context events,
  and the advisor never.
- The source is the session's transcript (registry `transcript`). Read the **last main-thread assistant entry**,
  `"type":"assistant"` without `isSidechain`, and take its top-level fields:
  - `message.model` (`claude-opus-5-5`)
  - `effort` (`low`, `medium`, `high`, `xhigh` or `max`)
  - `advisorModel` (empty when the advisor is off)
- These follow `/model`, `/effort` and `/advisor` changes.
- It is an internal format, so the rules are:
  - Read only the end of the file. Transcripts reach megabytes, and one entry can be large.
  - Windows caches the result until the file changes. Linux re-reads it (a 64 KB tail takes about 6 ms), and only in `ls`.
  - Fail soft: empty cells. A session that has not answered yet shows its configured values (settings and launch
    flags) in dim.

### Hook invariants (both ports)

- Print nothing on stdout. SessionStart and UserPromptSubmit stdout is injected into the model's context.
- Always exit 0 and stay fast.
- Do nothing unless the session is managed by roost:
  - Windows: env `ROOST_NAME`, set by `roost-run.ps1`.
  - Linux: tmux window option `@roost_managed=1`, set by `launch`/`adopt`.
- Session names must match `^[A-Za-z0-9._-]+$` on both ports.

### Settings roost must not touch

roost never passes `--model` or effort flags. Default claude flags come from `config/claude-flags`, which defaults to
`--permission-mode auto`. An explicit `--permission-mode` in the extra args replaces the default.

### Resume prompt

The auto-continue text exists in two places: a heredoc in `linux/bin/roost` and the file `windows/resume-prompt.txt`.
Change both. The user's copy is seeded only when it is missing (by `linux/bin/roost` on first run, by `install.ps1` on
Windows), so a changed default never reaches an existing install.
