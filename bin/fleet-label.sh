#!/usr/bin/env bash
# fleet-label.sh <session> <repo-name> <task-or-"none"> [roles...]
# Gives every fleet window a templated tab: "Coordinator@repo · TASK".
# Claude Code rewrites the pane TITLE (#T) with a rolling summary; themes
# that render #T in the tab therefore show noise. We (1) pin the window NAME
# (allow-rename/automatic-rename off) and (2) give fleet windows a private
# copy of the theme's window-status formats with #T swapped for #W, so only
# the fleet tabs change and the rest of the user's tmux keeps its look.
set -euo pipefail
session=$1; name=$2; task=$3; shift 3
roles=${*:-$(tmux list-windows -t "$session" -F '#{window_name}' | sed -E 's/@.*//' | tr 'A-Z' 'a-z')}
label_task=$task; [ "$task" = none ] && label_task=idle
fmt=$(tmux show-options -gv window-status-format 2>/dev/null || echo '#I:#W#F')
cfmt=$(tmux show-options -gv window-status-current-format 2>/dev/null || echo '#I:#W#F')
fmt=${fmt//\#T/\#W}; fmt=${fmt//\#\{pane_title\}/\#\{window_name\}}
cfmt=${cfmt//\#T/\#W}; cfmt=${cfmt//\#\{pane_title\}/\#\{window_name\}}
i=0
for role in $roles; do
  t="$session:$i"
  tmux set-option -w -t "$t" allow-rename off
  tmux set-option -w -t "$t" automatic-rename off
  tmux set-option -w -t "$t" window-status-format "$fmt"
  tmux set-option -w -t "$t" window-status-current-format "$cfmt"
  tmux rename-window -t "$t" "${role^}@$name · $label_task"
  i=$((i+1))
done
