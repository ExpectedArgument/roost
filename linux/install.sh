#!/usr/bin/env bash
# roost installer (Linux). Nothing is downloaded. Everything it touches is listed below, and backed up first.
#   ~/.local/bin/roost                      the command
#   ~/.claude/hooks/roost-hook.sh           state hook for Claude Code
#   ~/.claude/settings.json                 hooks merged in (backup: settings.json.pre-roost-<time>)
#   ~/.config/roost/tmux.conf               tmux settings; ~/.tmux.conf gets one `source-file` line
#   --systemd (needs sudo): /etc/systemd/system/roost-{tmux,restore}.service + loginctl enable-linger;
#                           started now only if no tmux server runs (else they take over at the next boot)
# Usage: ./install.sh [--systemd]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin/roost"
HOOKDIR="$HOME/.claude/hooks"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/roost"
SYSTEMD=0
[ "${1:-}" = "--systemd" ] && SYSTEMD=1

for c in tmux jq; do command -v "$c" >/dev/null || { echo "missing: $c  (sudo apt install $c)"; exit 1; }; done
command -v claude >/dev/null || echo "note: 'claude' not found in PATH (install Claude Code first, or set ROOST_CLAUDE_BIN)"
tmux -V | awk '{ if ($2+0 < 3.2) print "warning: tmux >= 3.2 recommended (you have " $2 ")" }'

mkdir -p "$(dirname "$BIN")" "$HOOKDIR" "$CONF"
install -m 755 "$HERE/bin/roost" "$BIN"
install -m 755 "$HERE/hooks/roost-hook.sh" "$HOOKDIR/roost-hook.sh"
sed "s|@ROOST_BIN@|$BIN|g" "$HERE/tmux.conf" >"$CONF/tmux.conf"
echo "installed: $BIN, $HOOKDIR/roost-hook.sh, $CONF/tmux.conf"

# ~/.tmux.conf: one source line (idempotent)
line="source-file $CONF/tmux.conf"
touch "$HOME/.tmux.conf"
grep -qxF "$line" "$HOME/.tmux.conf" || { printf '\n# roost\n%s\n' "$line" >>"$HOME/.tmux.conf"; echo "added to ~/.tmux.conf: $line"; }

# Claude Code hooks (existing settings are kept; backup first; untouched when nothing is missing)
SET="$HOME/.claude/settings.json"
src="$SET"
if [ ! -e "$SET" ]; then src="$(mktemp)"; echo '{}' >"$src"; fi
tmp="$(mktemp)"
jq --arg h "$HOOKDIR/roost-hook.sh" '
  def add($ev; $arg; $t):
    .hooks[$ev] = ((.hooks[$ev] // []) as $l
      | if any($l[]?.hooks[]?; (.command // "") | test("roost-hook")) then $l
        else $l + [{hooks: [{type: "command", command: ($h + " " + $arg), timeout: $t}]}] end);
  .hooks = (.hooks // {})
  | add("SessionStart"; "start"; 5) | add("UserPromptSubmit"; "busy"; 5) | add("Stop"; "idle"; 5)
  | add("Notification"; "attention"; 5) | add("SessionEnd"; "end"; 2) | add("PostToolUse"; "resume"; 5)
' "$src" >"$tmp"
if [ -e "$SET" ] && [ "$(jq -S . "$SET")" = "$(jq -S . "$tmp")" ]; then
  rm -f "$tmp"
  echo "hooks already registered in $SET (settings.json unchanged)"
else
  if [ -e "$SET" ]; then
    cp -p "$SET" "$SET.pre-roost-$(date +%Y%m%d-%H%M%S)"
    chmod --reference="$SET" "$tmp" # mktemp creates 0600: keep the file's own mode
    echo "settings.json backed up: $SET.pre-roost-*"
  fi
  mv "$tmp" "$SET"
  echo "hooks registered in $SET"
fi
[ "$src" = "$SET" ] || rm -f "$src"

if [ "$SYSTEMD" = 1 ]; then
  U="$(id -un)"; ID="$(id -u)"
  for u in roost-tmux roost-restore; do
    sed "s|@USER@|$U|g; s|@UID@|$ID|g; s|@HOME@|$HOME|g; s|@ROOST_BIN@|$BIN|g" "$HERE/systemd/$u.service.in" | sudo tee "/etc/systemd/system/$u.service" >/dev/null
  done
  sudo loginctl enable-linger "$U"
  sudo systemctl daemon-reload
  sudo systemctl enable roost-tmux.service roost-restore.service
  # roost-tmux is Type=forking with ExecStop=tmux kill-server. Started while another tmux server runs (default socket),
  # its `new-session` succeeds inside that server, the unit's cgroup stays empty, systemd runs ExecStop and every running
  # session dies. roost-restore Requires roost-tmux, so neither is started then: they take over at the next boot.
  if env -u TMUX tmux list-sessions >/dev/null 2>&1; then
    echo "systemd services enabled. A tmux server is already running, so they were NOT started now:"
    echo "they take over at the next boot, and sessions then come back after a reboot / power loss"
  else
    sudo systemctl start roost-tmux.service roost-restore.service
    echo "systemd services enabled and started: sessions come back after a reboot / power loss"
  fi
else
  echo "tip: re-run with --systemd to start sessions at boot and resume them after a power loss"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: add ~/.local/bin to PATH";; esac
echo "done. Try:  roost new demo ~/some/project     then   roost doctor"
