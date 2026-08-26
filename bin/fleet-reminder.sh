#!/usr/bin/env bash
# UserPromptSubmit hook: re-inject the role's one-line rules every turn,
# so they survive any context depth.
[ -n "${FLEET_ROLE:-}" ] || exit 0
FLEET_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
f="$FLEET_HOME/templates/reminders/${FLEET_ROLE}.txt"
[ -f "$f" ] && cat "$f"
r=".fleet/notes/${FLEET_ROLE}-reminder.txt"
[ -f "$r" ] && cat "$r"
exit 0
