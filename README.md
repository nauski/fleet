# fleet

Multi-agent Claude Code fleets in tmux: one coordinator + worker roles
(implementer / deployer / tester) per repository, with **deterministic context
lifecycle** — agent contexts are reset by script at every task boundary, so
long-running sessions never rot past usefulness.

## Why

Long-running interactive sessions give great visibility but accumulate stale
context (500k+ tokens → errors, stale memories). Subagents have fresh context
but no visibility. Fleet keeps the tmux visibility and moves everything
durable OUT of context into files, so contexts become disposable:

- role knowledge → rendered brief in `.fleet/roles/<role>.md` (+ repo CLAUDE.md)
- backlog → `.fleet/QUEUE.md`
- current task → `.fleet/HANDOFF.md`
- behavioral rules → re-injected EVERY turn by a UserPromptSubmit hook
  (immune to context depth)

The LLM's job shrinks to "detect task boundary → run one script". The script
owns the procedure (idle check, /clear, re-brief, verification).

## Quick start

```bash
~/fleet/bin/fleet-init.sh ~/src/myrepo            # scoping pass picks roles
~/fleet/bin/fleet-init.sh ~/src/myrepo --roles coordinator,implementer,tester
tmux attach -t fleet-myrepo
```

Then (once per repo, manual on purpose): merge
`myrepo/.fleet/settings.snippet.json` into `myrepo/.claude/settings.local.json`.
It contains the reminder hook and the permission allowlist that keeps
overnight runs from freezing on prompts.

## Role discovery

Order of precedence: `--roles` flag > committed `.fleet/fleet.conf`
(`ROLES="coordinator implementer tester"`) > one-shot `claude -p` scoping
draft (confirmed interactively, or `--yes`) > default `coordinator implementer`.

Discovery infers *testability*, never *intent* (which env is safe to hammer at
night). Intent lives in editable files: `.fleet/fleet.conf` and
`.fleet/notes/<role>.md` (appended to briefs), `.fleet/notes/<role>-reminder.txt`
(injected every turn).

## Scripts

| script | does |
|---|---|
| `fleet-init.sh <repo> [--roles a,b] [--yes] [--no-launch]` | stamp `.fleet/`, render briefs, launch tmux fleet |
| `reset-agent.sh <sess:win> <brief> [--wait\|--force]` | /clear + re-brief one agent; refuses mid-turn unless told |
| `switch-bug.sh <id> <summary>` | rewrite HANDOFF, reset peers, schedule coordinator self-reset |
| `fleet-reminder.sh` | UserPromptSubmit hook: cat role reminder every turn |
| `fleet-watchdog.sh` | cron: nudge hung panes (busy indicator + frozen output) |

## Overnight runs

1. Merge the settings snippet (permission prompts at 03:00 = frozen fleet).
2. `crontab -e`: `*/15 * * * * ~/fleet/bin/fleet-watchdog.sh >> ~/.cache/fleet-watchdog/log 2>&1`
3. Seed `.fleet/QUEUE.md` with the night's tasks; tell the coordinator to start.

The coordinator switches tasks itself: `switch-bug.sh` is its last action per
task — resets every peer and then itself, so each task starts with four fresh
contexts and zero stale-bug memory.

## Design notes

- Coordination between agents = `SendMessage` (they're peer Claude Code
  sessions). Resets = tmux send-keys, because a session cannot clear a peer's
  context by message.
- Briefs are re-sent as one-liners pointing at files ("read X, confirm task
  id") — multi-line send-keys would submit early.
- Busy detection = "esc to interrupt" in the pane. Watchdog only nudges
  busy-but-frozen panes; idle waiting is normal and nudging it burns context.
