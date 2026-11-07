# linux/ (bash + tmux + jq)

Port-specific notes. Shared design (hook events, state values, lifecycle, invariants) is in the root `CLAUDE.md`.

## Checking changes

There is no selftest. Run `roost doctor`. Knobs for testing without touching the real setup:

- `ROOST_TMUX_SOCKET`: a separate tmux server.
- `ROOST_STATE_DIR` / `ROOST_CONF_DIR`: isolated state and config.
- `ROOST_HOOK_DEBUG=1`: logs to `$STATE_DIR/hook.log`.
- `ROOST_UPTIME_OVERRIDE`: fakes a fresh boot for the crash-loop guard.
- `ROOST_NO_ATTACH=1`: no attach.

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
  (substituting `@USER@`, `@UID@`, `@HOME@` and `@ROOST_BIN@`) and enables linger.
- `uninstall.sh` backs up `settings.json`, then removes only the hook entries whose command matches `roost-hook`.
- `extras/recovery` holds hardware-specific watchdog, panic and NVMe settings. They are not installed by default.
  Never open `/dev/watchdog*` from a script, because opening it arms the timer.
