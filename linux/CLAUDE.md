# linux/ (bash + tmux + jq)

Port-specific notes. Shared design (hook events, state values, lifecycle, invariants) is in the root `CLAUDE.md`.

## Checking changes

`linux/bin/roost selftest` (about 8 s, exit 1 on any FAIL) runs `new`, the hook cycle, `ls`, `title`, `restore`, `close`
and the RC column against a throw-away tmux server. It takes the hook from `../hooks` next to the script, so run from the
repo it tests the repo copies; an installed copy falls back to `~/.claude/hooks`. `roost doctor` checks the installed setup.

How the selftest stays away from the real setup (keep this when you extend it):
- Your shell is usually a pane of the real server, and the hook follows `$TMUX` / `$TMUX_PANE`. Run by hand from a
  managed pane, the hook changes that live window and registry. `cmd_selftest` unsets both and hands them only to the
  hook calls for test windows.
- It uses its own socket (`roost-selftest-PID`) and temp `ROOST_STATE_DIR`, `ROOST_CONF_DIR`, `CLAUDE_CONFIG_DIR` and
  `ROOST_PROJECT_ROOT`. The server starts with `-f /dev/null`, so `~/.tmux.conf` is not loaded. Cleanup kills a server
  only when the socket name is set: `tmux kill-server` without `-L` kills the real one.
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

## Hook details (`hooks/roost-hook.sh`)

- `PostToolUse` → `resume` does nothing unless `@roost_state` is `attention`; then it acts as `busy`. That is how `?`
  clears right after a prompt is answered.
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
