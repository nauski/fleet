#!/usr/bin/env bash
# mr-edit.sh --host <gitlab host> --project <group%2Fproject> --iid <n>
#            [--title <text>] [--description-file <path>] [--labels <csv>]
# Edits ONE merge request's title/description/labels via the GitLab REST API.
# This is the only PUT fleet workers may issue: it can never merge, approve,
# close, or change target/source branches. Uses glab's stored token; unsets a
# stale GITLAB_TOKEN env var (it shadows the per-host config token).
set -euo pipefail
host="" project="" iid="" title="" descfile="" labels=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host=$2; shift 2 ;;
    --project) project=$2; shift 2 ;;
    --iid) iid=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --description-file) descfile=$2; shift 2 ;;
    --labels) labels=$2; shift 2 ;;
    *) echo "mr-edit.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$host" ] && [ -n "$project" ] && [ -n "$iid" ] || { echo "usage: mr-edit.sh --host H --project G%2FP --iid N [--title T] [--description-file F] [--labels L]" >&2; exit 2; }
case "$iid" in *[!0-9]*|'') echo "mr-edit.sh: --iid must be numeric" >&2; exit 2 ;; esac
[ -n "$title$descfile$labels" ] || { echo "mr-edit.sh: nothing to change" >&2; exit 2; }
args=()
[ -n "$title" ] && args+=(-f "title=$title")
[ -n "$labels" ] && args+=(-f "labels=$labels")
[ -n "$descfile" ] && args+=(-f "description=$(cat "$descfile")")
env -u GITLAB_TOKEN glab api --hostname "$host" --method PUT \
  "projects/$project/merge_requests/$iid" "${args[@]}" |
  python3 -c 'import sys,json; d=json.load(sys.stdin); print("updated MR", d.get("iid"), d.get("web_url"))'
