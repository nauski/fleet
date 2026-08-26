---
name: fleet-init
description: Use when the user wants to spin up an agent fleet (coordinator/implementer/deployer/tester in tmux) for a repository, reset a fleet agent's context, or switch the fleet to a new task. Triggers - "fleet init", "start a fleet", "spin up agents for this repo", "/fleet-init".
---

# Fleet

Scripts live in `~/fleet/bin`. Full docs: `~/fleet/README.md`.

## Start a fleet for a repo

```bash
~/fleet/bin/fleet-init.sh <repo-dir> [--roles coordinator,implementer,deployer,tester] [--yes] [--no-launch]
```

- No `--roles` and no `.fleet/fleet.conf` in the repo → a one-shot `claude -p`
  scoping pass drafts the role list; user confirms (or `--yes`).
- Renders role briefs into `<repo>/.fleet/roles/`, seeds `HANDOFF.md` +
  `QUEUE.md`, writes `.fleet/settings.snippet.json`.
- Launches tmux session `fleet-<reponame>`, one window per role, each running
  `claude --settings .fleet/settings.snippet.json` with its role brief and
  `FLEET_ROLE` set. The snippet carries the reminder hook + permission
  allowlist — the repo's own `.claude/settings.local.json` is never touched,
  and no manual merge is needed.

## Repo-specific knowledge

Put per-role facts (deploy targets, test env URLs, gotchas) in
`<repo>/.fleet/notes/<role>.md` before init — they get appended to the
rendered briefs. Per-role every-turn reminders: `.fleet/notes/<role>-reminder.txt`.

## Reset one agent

```bash
~/fleet/bin/reset-agent.sh fleet-<repo>:<role> .fleet/roles/<role>.md [--wait|--force]
```

Refuses if the agent is mid-turn unless `--wait` (poll ≤30 min) or `--force`.

## Switch the fleet to a new task

```bash
cd <repo> && ~/fleet/bin/switch-task.sh <task-id> "one-line brief"
```

Rewrites `HANDOFF.md`, resets all peers, schedules the coordinator's own reset.
The coordinator runs this itself as the last action of its turn.

## Watchdog (optional, for overnight)

Cron every 15 min: `~/fleet/bin/fleet-watchdog.sh` — nudges panes that show
the busy indicator but produce no output between ticks.
