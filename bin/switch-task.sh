#!/usr/bin/env bash
# switch-task.sh <task-id> <one-line summary...>
# Run from the COORDINATOR repo root (the coordinator does this as the LAST
# action of its turn). Updates HANDOFF.md, resets all peer windows (each in
# its own repo per fleet.conf ROLE_REPO_*), then schedules the coordinator's
# own reset in the background (fires once its current turn ends).
set -euo pipefail
task=$1; shift
summary="$*"
repo="$(pwd)"
[ -f "$repo/.fleet/fleet.conf" ] || { echo "no .fleet/fleet.conf — run from the coordinator repo root" >&2; exit 1; }
. "$repo/.fleet/fleet.conf"
NAME="$(basename "$repo")"
SESSION="fleet-$NAME"
bindir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
handoff="$repo/.fleet/HANDOFF.md"

role_repo() { local v="ROLE_REPO_$1"; printf '%s' "${!v:-$repo}"; }

{
  echo "# HANDOFF"
  echo "Current task: $task"
  echo "Summary: $summary"
  echo "Switched: $(date -Is)"
} > "$handoff"

"$bindir/fleet-label.sh" "$SESSION" "$NAME" "$task" $ROLES || echo "WARN: tab labels not updated" >&2

idx=0
for role in $ROLES; do
  win="$SESSION:$idx"; idx=$((idx+1))
  [ "$role" = coordinator ] && continue
  "$bindir/reset-agent.sh" "$win" "$(role_repo "$role")/.fleet/roles/$role.md" --wait --handoff "$handoff" \
    || echo "WARN: $role not reset" >&2
done

if printf '%s\n' $ROLES | grep -qx coordinator; then
  cidx=$(printf '%s\n' $ROLES | grep -nx coordinator | cut -d: -f1); cidx=$((cidx-1))
  nohup "$bindir/reset-agent.sh" "$SESSION:$cidx" "$repo/.fleet/roles/coordinator.md" --wait --handoff "$handoff" \
    >>"$repo/.fleet/reset.log" 2>&1 &
  echo "switched to $task — peers reset, coordinator self-reset scheduled"
else
  echo "switched to $task — peers reset"
fi
