# linux/ (bash + tmux + jq)

Port-specific notes. Shared design (hook events, state values, lifecycle, invariants) is in the root `CLAUDE.md`.

## Checking changes

`linux/bin/roost selftest` (about 12 s, 65 checks, exit 1 on any FAIL) runs `new`, the hook cycle, `ls` (RC and model
columns), `title`, `next`, `restore`, `close` and the environment scrub against a throw-away tmux server. It takes the hook from `../hooks` next to the script, so run from the
repo it tests the repo copies; an installed copy falls back to `~/.claude/hooks`. `roost doctor` checks the installed setup.

How the selftest stays away from the real setup (keep this when you extend it):
- Your shell is usually a pane of the real server, and the hook follows `$TMUX` / `$TMUX_PANE`. Run by hand from a
  managed pane, the hook changes that live window and registry. `cmd_selftest` unsets both and hands them only to the
  hook calls for test windows.
- It uses its own socket (`roost-selftest-PID`) and temp `ROOST_STATE_DIR`, `ROOST_CONF_DIR`, `CLAUDE_CONFIG_DIR` and
  `ROOST_PROJECT_ROOT`. The server starts with `-f /dev/null`, so `~/.tmux.conf` is not loaded. Cleanup kills a server
  only when the socket name is set: `tmux kill-server` without `-L` kills the real one.
- The test server is started with `CLAUDECODE=1` and friends in its environment, like one launched from a Claude Code
  tool shell, and the fake `claude` logs what it receives (`env.log`, `args.log`).
- The fake `claude` is a script that does `exec -a claude sleep`: tmux reads `pane_current_command` from argv[0], not
  from the script name. To simulate claude exiting, send SIGTERM: a Ctrl-C also ends the `bash -ic` wrapper, and the
  window disappears instead of becoming a SHELL window.

Knobs for your own isolated runs: `ROOST_TMUX_SOCKET` (a separate tmux server), `ROOST_STATE_DIR` / `ROOST_CONF_DIR`,
`ROOST_HOOK_DEBUG=1` (logs to `$STATE_DIR/hook.log`), `ROOST_UPTIME_OVERRIDE` (fakes a fresh boot for the crash-loop
guard), `ROOST_NO_ATTACH=1`.

## Design

- One tmux session (`ROOST_TMUX_SESSION`, default `roost`).
- Per-window options identify and track sessions: `@roost_managed`, `@roost_name`, `@roost_state` and `@roost_conn`.
  The `tmux.conf` status format reads `@roost_state` directly. The display state lives only there, not in the
  registry file.
- Window `dash` runs `watch roost ls --color`. A mouse binding in `tmux.conf` calls `roost click <line>` to jump to a
  session.
- `roost next` (tmux `Ctrl-b a`) selects the next window whose `@roost_state` is `attention`, then `waiting`, cycling
  from the caller's current window. The binding passes `#{session_name}` because `attach` makes a grouped
  `view-PID` session per client, each with its own current window.
- Open vs parked: a window exists and `pane_current_command` is `claude`. A window left with a plain shell shows as
  `SHELL`, and restore recreates it.
- The registry also stores `permission_mode` and `connectors`, and restore reapplies them. Sessions not listed in
  `connectors-allow` start with `ENABLE_CLAUDEAI_MCP_SERVERS=false`.
- `restore` holds a `flock` on fd 9. `tm()` closes fd 9 (`9>&-`) so a tmux server started from inside restore does
  not inherit the lock forever.

## RC column and tab title

The shared rules are in the root `CLAUDE.md`. Linux specifics:

- `rc_index` fills `RCI` (session id → `on`/`off`) for `ls`. The pid is also the file name, so stale files are skipped
  before `jq` parses them. `proc_start` reads field 22 of `/proc/PID/stat` after cutting everything up to the last `) `,
  because the command name may contain spaces and parentheses.
- `roost title` prints the tab title. `tmux.conf` sets `set-titles on` and `set-titles-string '#(roost title)'`, so the
  title refreshes with the status bar. The first expansion after an attach is empty for a moment, until the job has run.

## `ls` columns: model, effort, advisor

- `cmd_ls` adds MODEL / EFFORT / ADVISOR after RC. `tx_info` reads the end of the transcript (64 KB, then 1 MB, then
  8 MB). `cfg_info` supplies the dim "configured" values while there is no answer yet: project and user settings, then
  `claude-flags` and the flags `roost new` got, which `launch` keeps in the window option `@roost_extra`.
- Only `ls` reads transcripts. `status` and `title` run `collect` on every status interval and must stay cheap.
- Widths come from `COLUMNS` (watch exports it), else `tput cols` on a tty, else 120. The directory column keeps at
  least 16 characters, so ADVISOR drops first. The selftest cuts `ls` at fixed offsets (STATE 20-26, RC 34-36, MODEL
  38-47, EFFORT 49-54, ADVISOR 56-65): a new column goes after them.

## Environment and window lifecycle

- A tmux server started from a Claude Code tool shell hands that shell's variables to every window. `CLAUDECODE=1`
  makes claude refuse to start as a nested session. `LEAK_VARS` lists them; `ensure_server` and the `inner` command
  of `launch` drop them, only when `CLAUDECODE` is set (the user's own `NO_COLOR` etc. stay).
- `launch` hands `ROOST_STATE_DIR` to the window with `-e`, so that window's hook writes where `roost` reads.
- `restore` creates the new window **before** killing a leftover shell, and kills last: `roost restore NAME` may be
  typed inside that very shell. `attach_to` closes fd 9, so an attached client does not hold the restore lock.
- `close` removes the registry entry first and again after the kill, because a hook may rewrite it while claude exits.
  It sends Escape (cancels a pending `?` prompt), pauses 0.3 s so it is not read as Alt+/, then `/exit`.

## Hook details (`hooks/roost-hook.sh`)

- `PostToolUse` → `resume` does nothing unless `@roost_state` is `attention`; then it acts as `busy`. That is how `?`
  clears right after a prompt is answered. It exits before any `jq` call: it runs after every tool call of every session.
- `permission_mode`: the event's value, else the one already in the registry, else `auto`.
- A `Notification` is classified by `notification_type` (or by its message text when the type is missing).
  `permission_prompt` and `elicitation_dialog` set `attention`. `idle_prompt` sets display `waiting`, not `attention`.
  Anything else keeps the current display state.

## Config defaults are seeded once

`linux/bin/roost` creates `claude-flags` (`--permission-mode auto`), `connectors-allow` (`*`, so connectors stay on
everywhere by default) and `resume-prompt.txt` (a heredoc in the script) in `~/.config/roost` only when they are
missing. Changing a default in the repo never reaches an existing install.

## Install

- `install.sh --systemd` installs `roost-tmux.service` and `roost-restore.service` from the `systemd/*.in` templates
  (substituting `@USER@`, `@UID@`, `@HOME@` and `@ROOST_BIN@`), enables linger and enables the units.
  - It starts them only when no tmux server runs (`env -u TMUX tmux list-sessions`). `roost-tmux` is `Type=forking`
    with `ExecStop=tmux kill-server`: started next to a running server, its cgroup stays empty, systemd runs
    ExecStop and every session dies. `roost-restore` `Requires` it, so it is not started either. Never `start`
    `roost-tmux` by hand while a server runs; the units take over at the next boot.
  - Test it with a stub `sudo` on `PATH` and a private `TMUX_TMPDIR` (short path: socket paths are limited to about
    100 characters), never for real on a machine with live sessions.
- `uninstall.sh` backs up `settings.json`, then removes only the hook entries whose command matches `roost-hook`.
- `extras/recovery` holds hardware-specific watchdog, panic and NVMe settings. They are not installed by default.
  Never open `/dev/watchdog*` from a script, because opening it arms the timer.
