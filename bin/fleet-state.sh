#!/usr/bin/env bash
# fleet-state.sh <working|idle|notification>
# Claude Code hook target: records the agent's state as a tmux window user
# option (@fleet_state) so the tab can show it. Runs inside the agent's pane,
# so $TMUX_PANE identifies the window. Silent no-op outside tmux.
# "notification" reads the hook's JSON on stdin and maps permission prompts
# to "attention"; other notification types (idle reminders) are ignored.
[ -n "${TMUX_PANE:-}" ] || exit 0
state=${1:-idle}
if [ "$state" = notification ]; then
  t=$(jq -r '.notification_type // .type // empty' 2>/dev/null || true)
  case "$t" in *permission*) state=attention ;; *) exit 0 ;; esac
fi
case "$state" in
  working)   icon='●' ;;
  attention) icon='!' ;;
  *)         icon='○' ;;
esac
tmux set-option -w -t "$TMUX_PANE" @fleet_state "$state" 2>/dev/null || true
tmux set-option -w -t "$TMUX_PANE" @fleet_icon "$icon" 2>/dev/null || true
exit 0
