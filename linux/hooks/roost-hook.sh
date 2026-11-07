#!/usr/bin/env bash
# Claude Code hook for `roost` (tmux session manager).
# Keeps a tiny per-window registry so sessions can be resumed after a power loss / reboot,
# and mirrors the state into tmux (@roost_state) for the status bar.
#
# RULES: stay SILENT on stdout (SessionStart / UserPromptSubmit stdout is injected into the model
#        context = wasted tokens), always exit 0, never block, finish in a few ms.
#        No-op outside tmux windows that were created / adopted by `roost`.
#
# Usage (from settings.json hooks):  roost-hook.sh start|busy|idle|attention|resume|end
# display states: busy=working  attention=needs a decision (?)  waiting=finished, wants your next message (*)  idle=quiet (o)   (JSON on stdin)

[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

ev="${1:-}"
input="$(cat 2>/dev/null)"

IFS='|' read -r managed name conn curstate < <(tmux display-message -p -t "$TMUX_PANE" '#{@roost_managed}|#{@roost_name}|#{@roost_conn}|#{@roost_state}' 2>/dev/null)
[ "${managed:-}" = "1" ] && [ -n "${name:-}" ] || exit 0
# PostToolUse: only meaningful when a '?' prompt was just answered (tool ran => working again)
if [ "$ev" = resume ]; then [ "${curstate:-}" = attention ] || exit 0; ev=busy; fi

state_root="${ROOST_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/roost}"
dir="$state_root/sessions"
f="$dir/$name.json"
dbg() { [ -n "${ROOST_HOOK_DEBUG:-}" ] && printf '%s %s %s\n' "$(date +%T.%N | cut -c1-12)" "$name" "$*" >>"$state_root/hook.log"; return 0; }
setstate() { tmux set-option -w -q -t "$TMUX_PANE" @roost_state "$1" 2>/dev/null; return 0; }

mkdir -p "$dir" 2>/dev/null || exit 0

IFS=$'\x1f' read -r sid cwd tp pm src reason msg ntype < <(printf '%s' "$input" | jq -r '[(.session_id//""),(.cwd//""),(.transcript_path//""),(.permission_mode//""),(.source//""),(.reason//""),((.message//"")|gsub("[\n\t\u001f]";" ")),(.notification_type//"")]|join("\u001f")' 2>/dev/null)

if [ "$ev" = "end" ]; then
  dbg "end reason=${reason:-?}"
  # Only an explicit user exit forgets the session. SIGHUP / reboot / kill-server (reason "other",
  # "resume", "clear") must keep the entry so the session is resumed later.
  case "${reason:-}" in
    prompt_input_exit|logout) rm -f "$f"; setstate "" ;;
  esac
  exit 0
fi

old_state=""
[ -r "$f" ] && old_state="$(jq -r '.state // empty' "$f" 2>/dev/null)"

case "$ev" in
  busy) st=busy; ds=busy ;;
  idle) st=idle; ds=waiting ;;
  start)
    # after an auto-compaction in the middle of a turn the session is still working
    if [ "${src:-}" = compact ] && [ -n "$old_state" ]; then st="$old_state"; else st=idle; fi
    ds="$st" ;;
  attention)
    nt="${ntype:-}"
    if [ -z "$nt" ]; then
      case "${msg:-}" in *"waiting for your input"*|*"waiting for input"*) nt=idle_prompt ;; *) nt=permission_prompt ;; esac
    fi
    case "$nt" in
      permission_prompt|elicitation_dialog) ds=attention; st="${old_state:-idle}" ;;
      idle_prompt) ds=waiting; st=idle ;;
      *) ds="${curstate:-idle}"; st="${old_state:-idle}" ;;
    esac ;;
  *) exit 0 ;;
esac

if [ -n "${sid:-}" ]; then
  tmpf="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || { setstate "$ds"; exit 0; }
  if jq -n -c --arg name "$name" --arg sid "$sid" --arg cwd "${cwd:-$PWD}" --arg tp "${tp:-}" \
        --arg pm "${pm:-auto}" --arg st "$st" --argjson now "$(date +%s)" --arg conn "${conn:-}" \
        '{name:$name, cwd:$cwd, session_id:$sid, transcript:$tp, permission_mode:$pm, state:$st, connectors:($conn=="1"), updated:$now}' \
        >"$tmpf" 2>/dev/null && [ -s "$tmpf" ]; then
    mv -f "$tmpf" "$f"
  else
    rm -f "$tmpf"
  fi
fi
setstate "$ds"
dbg "$ev state=$st src=${src:-}"
exit 0
