#!/usr/bin/env bash
# reset-agent.sh <session:window> <brief-file> [--force|--wait] [--handoff <file>]
# Clears a fleet agent's context and re-briefs it. Refuses if the agent is
# mid-turn ("esc to interrupt" visible) unless --force, or polls until idle
# with --wait (max 30 min). --handoff names the HANDOFF file to point the
# agent at (default .fleet/HANDOFF.md relative to the agent's own cwd; pass an
# absolute path when the role runs in a different repo than the coordinator).
set -euo pipefail
target=$1; brief=$2; shift 2
mode="" handoff=".fleet/HANDOFF.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --force|--wait) mode=$1; shift ;;
    --handoff) handoff=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

busy() { tmux capture-pane -p -t "$target" | grep -q "esc to interrupt"; }

if busy; then
  case "$mode" in
    --force) : ;;
    --wait)
      for _ in $(seq 1 180); do sleep 10; busy || break; done
      if busy; then echo "TIMEOUT: $target still busy after 30 min — not reset" >&2; exit 1; fi
      ;;
    *) echo "BUSY: $target mid-turn — not reset (--force to override, --wait to poll)" >&2; exit 1 ;;
  esac
fi

tmux send-keys -t "$target" "/clear" Enter
sleep 3
# One line only: multi-line send-keys would submit early. The brief itself is a file.
tmux send-keys -t "$target" -l "Fresh start after context reset. Read $brief for your role, then $handoff for the current task. Confirm by stating the current task id, then proceed."
sleep 1
tmux send-keys -t "$target" Enter
echo "reset OK: $target"
