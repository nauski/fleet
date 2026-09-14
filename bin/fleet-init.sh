#!/usr/bin/env bash
# fleet-init.sh <repo-dir> [--roles a,b,c] [--yes] [--no-launch]
# Stamps .fleet/ into the coordinator repo (and each role's repo when
# fleet.conf maps a role elsewhere), renders briefs + per-role permission
# snippets, launches the tmux fleet. Each window runs
#   FLEET_ROLE=<role> claude --settings .fleet/settings.<role>.json
# in the role's own repo, so no repo .claude/settings*.json is ever touched.
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
# fleet.conf is shell-sourceable:
#   ROLES="coordinator implementer deployer tester"
#   ROLE_REPO_deployer=/abs/path/to/infra-repo      # optional, per role
#   ROLE_REPO_tester=/abs/path/to/e2e-repo
# A role without ROLE_REPO_<role> runs in the coordinator repo.
[ -f "$conf" ] && . "$conf"
if [ -n "$roles_override" ]; then
  ROLES="$roles_override"
elif [ -z "${ROLES:-}" ]; then
  echo "no ROLES in $conf — drafting one with a scoping pass (claude -p)..."
  draft="$( cd "$repo" && claude -p --allowedTools "Read,Glob,Grep" \
    "Inspect this repository (README, CI config, Dockerfile/compose, test dirs, deploy scripts). Decide which fleet roles apply out of: coordinator implementer deployer tester. coordinator+implementer always apply; add deployer only if there is a deploy story, tester only if there is a runnable test/e2e story. Output ONLY one shell-sourceable line, no markdown, no explanation, e.g.: ROLES=\"coordinator implementer tester\"" \
    2>/dev/null || true )"
  if printf '%s\n' "$draft" | grep -q '^ROLES='; then
    eval "$(printf '%s\n' "$draft" | grep '^ROLES=' | head -1)"
  else
    ROLES="coordinator implementer"
    echo "scoping pass failed — defaulted to coordinator implementer"
  fi
  echo "drafted: ROLES=\"$ROLES\""
  if [ "$auto_yes" -ne 1 ]; then
    read -r -p "accept? [y/N/edit roles csv] " ans
    case "$ans" in
      y|Y) : ;;
      *,*|coordinator*|implementer*|deployer*|tester*) ROLES="${ans//,/ }" ;;
      *) echo "aborted"; exit 1 ;;
    esac
  fi
fi
# persist: switch-task.sh sources this. Keep ROLE_REPO_* lines as they were.
{
  echo "ROLES=\"$ROLES\""
  [ -f "$conf" ] && grep '^ROLE_REPO_' "$conf" || true
} > "$conf.tmp" && mv "$conf.tmp" "$conf"
. "$conf"
echo "roles: $ROLES"

role_repo() { # $1=role -> absolute repo dir for that role
  local v="ROLE_REPO_$1"
  local d="${!v:-$repo}"
  ( cd "$d" && pwd )
}

# --- per-role settings snippet -----------------------------------------------
# base.json + templates/permissions/<role>.json + <role_repo>/.fleet/notes/<role>-allow.json
# deep-merged (dicts merge, arrays concatenate+dedupe). $FLEET_HOME expanded.
render_settings() { # $1=role $2=role_repo
  FLEET_HOME="$FLEET_HOME" python3 - "$1" "$2" "$FLEET_HOME" <<'PY'
import json, os, sys
role, rrepo, home = sys.argv[1:4]
def load(p):
    if not os.path.exists(p): return {}
    with open(p) as f: return json.loads(f.read().replace("$FLEET_HOME", home))
def merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items(): out[k] = merge(a[k], v) if k in a else v
        return out
    if isinstance(a, list) and isinstance(b, list):
        out = list(a); [out.append(x) for x in b if x not in out]; return out
    return b
tpl = os.path.join(home, "templates", "permissions", role + ".json")
if not os.path.exists(tpl):
    sys.exit(f"no permission template for role '{role}' ({tpl})")
merged = {}
for p in (os.path.join(home, "templates", "permissions", "base.json"), tpl,
          os.path.join(rrepo, ".fleet", "notes", role + "-allow.json")):
    merged = merge(merged, load(p))
merged.pop("_comment", None)
mode = merged.get("permissions", {}).get("defaultMode")
if mode not in ("auto", "dontAsk", "acceptEdits", "default", "plan"):
    sys.exit(f"role {role}: permissions.defaultMode must be set in the template (got {mode!r})")
out = os.path.join(rrepo, ".fleet", f"settings.{role}.json")
with open(out, "w") as f: json.dump(merged, f, indent=2); f.write("\n")
print(f"  {role}: {out} (defaultMode={mode}, allow={len(merged['permissions'].get('allow', []))}, deny={len(merged['permissions'].get('deny', []))})")
PY
}

# --- render briefs + snippets per role --------------------------------------
export REPO="$repo" NAME SESSION ROLES FLEET_HOME
export HANDOFF="$repo/.fleet/HANDOFF.md" QUEUE="$repo/.fleet/QUEUE.md"
echo "settings snippets:"
for role in $ROLES; do
  rrepo="$(role_repo "$role")"
  mkdir -p "$rrepo/.fleet/roles" "$rrepo/.fleet/notes"
  tpl="$FLEET_HOME/templates/roles/$role.md"
  [ -f "$tpl" ] || { echo "no template for role '$role'" >&2; exit 1; }
  out="$rrepo/.fleet/roles/$role.md"
  envsubst '$REPO $NAME $SESSION $ROLES $FLEET_HOME $HANDOFF $QUEUE' < "$tpl" > "$out"
  [ "$rrepo" != "$repo" ] && printf '\nThis role runs in its own repository `%s`; the fleet state files above live in the coordinator repo `%s`.\n' "$rrepo" "$repo" >> "$out"
  notes="$rrepo/.fleet/notes/$role.md"
  [ -f "$notes" ] && { printf '\n## Repo-specific notes\n\n' >> "$out"; cat "$notes" >> "$out"; }
  if [ -d "$rrepo/.git" ]; then
    grep -qx '.fleet/' "$rrepo/.git/info/exclude" 2>/dev/null || echo '.fleet/' >> "$rrepo/.git/info/exclude"
  fi
  render_settings "$role" "$rrepo"
done

# --- seed state files (coordinator repo only) --------------------------------
[ -f "$HANDOFF" ] || printf '# HANDOFF\nCurrent task: none\n' > "$HANDOFF"
[ -f "$QUEUE" ]   || printf '# QUEUE\n\n- [ ] (add tasks here)\n' > "$QUEUE"

# --- launch tmux fleet -------------------------------------------------------
launch_cmd() { # $1=role
  printf 'FLEET_ROLE=%s claude --settings .fleet/settings.%s.json "$(cat .fleet/roles/%s.md)"' "$1" "$1" "$1"
}
if [ "$no_launch" -eq 1 ]; then
  echo "rendered. launch manually or rerun without --no-launch. Would run:"
  for role in $ROLES; do
    echo "  tmux window $SESSION:$role in $(role_repo "$role") -> $(launch_cmd "$role")"
  done
  exit 0
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "tmux session $SESSION already exists — attach or kill it first" >&2; exit 1
fi
first=1
for role in $ROLES; do
  rrepo="$(role_repo "$role")"
  if [ "$first" -eq 1 ]; then
    tmux new-session -d -s "$SESSION" -n "$role" -c "$rrepo"; first=0
  else
    tmux new-window -t "$SESSION" -n "$role" -c "$rrepo"
  fi
  # Pin the tab name to the role: Claude Code sets the terminal title to a
  # rolling conversation summary, and tmux copies that into the window name
  # when allow-rename is on.
  tmux set-option -w -t "$SESSION:$role" allow-rename off
  tmux set-option -w -t "$SESSION:$role" automatic-rename off
  tmux send-keys -t "$SESSION:$role" "$(launch_cmd "$role")" Enter
done
echo "fleet up: tmux attach -t $SESSION"
