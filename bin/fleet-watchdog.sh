#!/usr/bin/env bash
# fleet-watchdog.sh — run from cron (e.g. */15). Nudges panes that look HUNG:
# busy indicator visible but output unchanged since last tick. Idle panes are
# left alone (waiting for work is normal; nudging idle agents burns context).
set -u
state="$HOME/.cache/fleet-watchdog"; mkdir -p "$state"
tmux list-sessions -F '#S' 2>/dev/null | grep '^fleet-' | while read -r s; do
  tmux list-windows -t "$s" -F '#W' | while read -r w; do
    pane="$(tmux capture-pane -p -t "$s:$w" 2>/dev/null)" || continue
    h="$(printf '%s' "$pane" | md5sum | cut -d' ' -f1)"
    f="$state/$s-$w"
    prev="$(cat "$f" 2>/dev/null || true)"
    printf '%s\n' "$h" > "$f"
    if [ "$h" = "$prev" ] && printf '%s' "$pane" | grep -q "esc to interrupt"; then
      tmux send-keys -t "$s:$w" Escape
      sleep 2
      tmux send-keys -t "$s:$w" -l "Watchdog: you appeared hung (no output for 15+ min). State your status, re-read .fleet/HANDOFF.md, and continue — or message the coordinator if blocked."
      sleep 1
      tmux send-keys -t "$s:$w" Enter
      echo "$(date -Is) nudged $s:$w"
    fi
  done
done
