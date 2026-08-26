#!/usr/bin/env bash
# switch-task.sh <task-id> <one-line summary...>
# Run from repo root (the coordinator does this as the LAST action of its turn).
# Updates HANDOFF.md, resets all peer windows, then schedules the coordinator's
# own reset in the background (fires once its current turn ends).
set -euo pipefail
task=$1; shift
summary="$*"
repo="$(pwd)"
[ -f "$repo/.fleet/fleet.conf" ] || { echo "no .fleet/fleet.conf — run from repo root" >&2; exit 1; }
. "$repo/.fleet/fleet.conf"
NAME="$(basename "$repo")"
SESSION="fleet-$NAME"
bindir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

{
  echo "# HANDOFF"
  echo "Current task: $task"
  echo "Summary: $summary"
  echo "Switched: $(date -Is)"
} > "$repo/.fleet/HANDOFF.md"

for role in $ROLES; do
  [ "$role" = coordinator ] && continue
  "$bindir/reset-agent.sh" "$SESSION:$role" ".fleet/roles/$role.md" --wait \
    || echo "WARN: $role not reset" >&2
done

if printf '%s\n' $ROLES | grep -qx coordinator; then
  nohup "$bindir/reset-agent.sh" "$SESSION:coordinator" ".fleet/roles/coordinator.md" --wait \
    >>"$repo/.fleet/reset.log" 2>&1 &
  echo "switched to $task — peers reset, coordinator self-reset scheduled"
else
  echo "switched to $task — peers reset"
fi
