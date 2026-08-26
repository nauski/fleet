#!/usr/bin/env bash
# fleet-init.sh <repo-dir> [--roles a,b,c] [--yes] [--no-launch]
# Stamps .fleet/ into the repo, wires hook+permissions, launches tmux fleet.
set -euo pipefail

FLEET_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo="" roles_override="" auto_yes=0 no_launch=0
while [ $# -gt 0 ]; do
  case "$1" in
    --roles) roles_override="${2//,/ }"; shift 2 ;;
    --yes) auto_yes=1; shift ;;
    --no-launch) no_launch=1; shift ;;
    *) repo="$(cd "$1" && pwd)"; shift ;;
  esac
done
[ -n "$repo" ] || { echo "usage: fleet-init.sh <repo> [--roles a,b,c] [--yes] [--no-launch]" >&2; exit 1; }

NAME="$(basename "$repo")"
SESSION="fleet-$NAME"
conf="$repo/.fleet/fleet.conf"
mkdir -p "$repo/.fleet/roles" "$repo/.fleet/notes"

# --- roles: CLI flag > manifest > scoping draft > default -------------------
if [ -n "$roles_override" ]; then
  ROLES="$roles_override"
elif [ -f "$conf" ]; then
  . "$conf"
else
  echo "no $conf — drafting one with a scoping pass (claude -p)..."
  ( cd "$repo" && claude -p --allowedTools "Read,Glob,Grep" \
    "Inspect this repository (README, CI config, Dockerfile/compose, test dirs, deploy scripts). Decide which fleet roles apply out of: coordinator implementer deployer tester. coordinator+implementer always apply; add deployer only if there is a deploy story, tester only if there is a runnable test/e2e story. Output ONLY one shell-sourceable line, no markdown, no explanation, e.g.: ROLES=\"coordinator implementer tester\"" \
  ) > "$conf" 2>/dev/null || true
  if ! grep -q '^ROLES=' "$conf" 2>/dev/null; then
    echo 'ROLES="coordinator implementer"' > "$conf"
    echo "scoping pass failed — defaulted to coordinator implementer"
  fi
  echo "drafted $conf:"; cat "$conf"
  if [ "$auto_yes" -ne 1 ]; then
    read -r -p "accept? [y/N/edit roles csv] " ans
    case "$ans" in
      y|Y) : ;;
      *,*|coordinator*|implementer*|deployer*|tester*)
        echo "ROLES=\"${ans//,/ }\"" > "$conf" ;;
      *) echo "aborted"; exit 1 ;;
    esac
  fi
  . "$conf"
fi
echo "ROLES=\"$ROLES\"" > "$conf"   # persist: switch-bug.sh sources this
echo "roles: $ROLES"

# --- render role briefs ------------------------------------------------------
export REPO="$repo" NAME SESSION ROLES FLEET_HOME
for role in $ROLES; do
  tpl="$FLEET_HOME/templates/roles/$role.md"
  [ -f "$tpl" ] || { echo "no template for role '$role'" >&2; exit 1; }
  out="$repo/.fleet/roles/$role.md"
  envsubst '$REPO $NAME $SESSION $ROLES $FLEET_HOME' < "$tpl" > "$out"
  notes="$repo/.fleet/notes/$role.md"
  [ -f "$notes" ] && { printf '\n## Repo-specific notes\n\n' >> "$out"; cat "$notes" >> "$out"; }
done

# --- seed state files --------------------------------------------------------
[ -f "$repo/.fleet/HANDOFF.md" ] || printf '# HANDOFF\nCurrent task: none\n' > "$repo/.fleet/HANDOFF.md"
[ -f "$repo/.fleet/QUEUE.md" ]   || printf '# QUEUE\n\n- [ ] (add tasks here)\n' > "$repo/.fleet/QUEUE.md"

# --- git exclude .fleet ------------------------------------------------------
if [ -d "$repo/.git" ]; then
  grep -qx '.fleet/' "$repo/.git/info/exclude" 2>/dev/null || echo '.fleet/' >> "$repo/.git/info/exclude"
fi

# --- hook + permissions: emit snippet for the user to merge ------------------
# (Deliberately not auto-merged into .claude/settings.local.json: a script that
# grants itself permissions is the wrong kind of automation. Human merges once.)
cat > "$repo/.fleet/settings.snippet.json" <<EOF
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$FLEET_HOME/bin/fleet-reminder.sh" } ] }
    ]
  },
  "permissions": {
    "allow": [
      "Bash($FLEET_HOME/bin/reset-agent.sh:*)",
      "Bash($FLEET_HOME/bin/switch-bug.sh:*)",
      "Bash(tmux send-keys:*)",
      "Bash(tmux capture-pane:*)",
      "Bash(tmux list-windows:*)"
    ]
  }
}
EOF
if [ ! -f "$repo/.claude/settings.local.json" ]; then
  echo "ACTION NEEDED: no $repo/.claude/settings.local.json —"
  echo "  copy .fleet/settings.snippet.json there before launching overnight runs."
else
  echo "ACTION NEEDED: merge $repo/.fleet/settings.snippet.json into $repo/.claude/settings.local.json"
fi

# --- launch tmux fleet -------------------------------------------------------
if [ "$no_launch" -eq 1 ]; then
  echo "rendered. launch manually or rerun without --no-launch. Would run:"
  for role in $ROLES; do
    echo "  tmux window $SESSION:$role -> FLEET_ROLE=$role claude \"\$(cat .fleet/roles/$role.md)\""
  done
  exit 0
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session $SESSION already exists — attach or kill it first" >&2; exit 1
fi
first=1
for role in $ROLES; do
  if [ "$first" -eq 1 ]; then
    tmux new-session -d -s "$SESSION" -n "$role" -c "$repo"; first=0
  else
    tmux new-window -t "$SESSION" -n "$role" -c "$repo"
  fi
  tmux send-keys -t "$SESSION:$role" "FLEET_ROLE=$role claude \"\$(cat .fleet/roles/$role.md)\"" Enter
done
echo "fleet up: tmux attach -t $SESSION"
