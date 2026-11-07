#!/usr/bin/env bash
# Removes roost. Sessions' Claude conversations are not touched. Hooks are removed from settings.json (backup first).
set -euo pipefail
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/roost"
SET="$HOME/.claude/settings.json"
if [ -e /etc/systemd/system/roost-tmux.service ]; then
  sudo systemctl disable --now roost-restore.service roost-tmux.service || true
  sudo rm -f /etc/systemd/system/roost-tmux.service /etc/systemd/system/roost-restore.service
  sudo systemctl daemon-reload
fi
if [ -e "$SET" ]; then
  cp -p "$SET" "$SET.pre-uninstall-roost-$(date +%Y%m%d-%H%M%S)"
  tmp="$(mktemp)"
  jq '.hooks |= (if . == null then . else with_entries(.value |= map(select(any(.hooks[]?; (.command // "") | test("roost-hook")) | not))) | with_entries(select(.value | length > 0)) end)' "$SET" >"$tmp" && mv "$tmp" "$SET"
fi
sed -i '\|# roost$|d; \|source-file .*/roost/tmux.conf|d' "$HOME/.tmux.conf" 2>/dev/null || true
rm -f "$HOME/.local/bin/roost" "$HOME/.claude/hooks/roost-hook.sh"
echo "removed. Config/state kept: $CONF and ~/.local/state/roost (delete them if you like)."
