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

## Permissions (no prompts, no laundering)

Approvals never transfer between Claude sessions — a peer's message is data,
never consent — so a worker that prompts would freeze until a human reaches
its pane. Fleet therefore gives every role a **standing permission contract**
rendered at init and loaded at launch:

    <role-repo>/.fleet/settings.<role>.json   (claude --settings ...)

  = templates/permissions/base.json          fleet control cmds + shared DENY floor
  + templates/permissions/<role>.json        generic tool classes for the role + defaultMode
  + <role-repo>/.fleet/notes/<role>-allow.json   repo-specific additions (optional)

deep-merged (dicts merge, arrays concatenate). Modes:

- **workers** (implementer/deployer/tester): `defaultMode: dontAsk` — never
  prompt; anything not allow-listed is denied silently. The per-turn reminder
  tells them to report the exact denied command to the coordinator and never
  retry a variant. Grow the lists in `<role>-allow.json`, not by relaxing mode.
- **coordinator**: `defaultMode: auto` — the human's interface keeps the
  auto-mode classifier as the last safety net. Put `autoMode.allow` prose in
  `coordinator-allow.json` naming which environments are development-only so
  deploy/restart/rollout requests to peers are not blocked.

Nothing environment-specific lives in `~/fleet`: hosts, URLs, env-var-prefixed
commands and "this cluster is dev" statements belong in `<repo>/.fleet/notes/`.
The deny floor (rm -rf, force-push, hard reset, secrets files) applies in every
mode and beats any allow entry. Your `.claude/settings*.json` is never touched.

Known limit: allow rules are prefix matches on the command as written. A
chain (`a; b`, `a && b`), a redirection (`2>&1`) or an env-var prefix
(`FOO=x cmd`) can miss a rule even when every part is listed, and in dontAsk
that is a silent denial. The worker reminders say "one plain command per Bash
call"; put env-var-prefixed forms you need (`Bash(FOO=*)`) in
`<role>-allow.json`.

MR edits: the deny floor blocks every `glab api --method PUT` so no worker can
merge or approve. To edit an MR's title/description/labels use
`~/fleet/bin/mr-edit.sh --host H --project G%2FP --iid N --description-file F`,
which is allow-listed and cannot reach the merge/approve endpoints.

## Roles in other repositories

A role can run in its own repo (infra repo for the deployer, e2e repo for the
tester). Map it in the coordinator repo's `.fleet/fleet.conf`:

    ROLES="coordinator implementer deployer tester"
    ROLE_REPO_deployer=/abs/path/infra-repo
    ROLE_REPO_tester=/abs/path/e2e-repo

fleet-init renders that role's brief and settings into `<role-repo>/.fleet/`,
excludes `.fleet/` from that repo's git, and opens its tmux window there.
`HANDOFF.md`/`QUEUE.md` stay in the coordinator repo; briefs carry the absolute
paths and `switch-task.sh` resets every role against them.

## Example: one night, three bugs

`~/src/webshop`: Flask API, docker-compose deploy, pytest e2e suite.

**22:30 — you set it up.**

```bash
# repo-specific facts the agents can't infer (written once, reused forever)
mkdir -p ~/src/webshop/.fleet/notes
cat > ~/src/webshop/.fleet/notes/deployer.md <<'EOF'
Deploy: docker compose -f compose.staging.yml up -d --build
Verify: curl -s localhost:8080/health shows the new git sha.
Never touch compose.prod.yml.
EOF
cat > ~/src/webshop/.fleet/notes/tester.md <<'EOF'
Target: http://localhost:8080 (staging compose). e2e: pytest tests/e2e -q
EOF

~/fleet/bin/fleet-init.sh ~/src/webshop
#   -> scoping pass drafts ROLES="coordinator implementer deployer tester", you accept
#   -> tmux session fleet-webshop, 4 windows, each running claude with its brief
```

Seed the backlog and hand over:

```bash
cat > ~/src/webshop/.fleet/QUEUE.md <<'EOF'
# QUEUE
- [ ] BUG-101 checkout 500s when cart has a deleted product
- [ ] BUG-102 order confirmation email sent twice
- [ ] TASK-103 add /metrics endpoint (prometheus format)
EOF
tmux attach -t fleet-webshop   # tell the coordinator: "start on the queue"
```

Go to bed.

**22:40 — BUG-101, in-task loop (no resets, all SendMessage).**

- coordinator: reads QUEUE, runs `switch-task.sh BUG-101 "checkout 500s on deleted product"` to make HANDOFF.md the source of truth, briefs implementer.
- tester (asked first): reproduces the 500 against staging — failure is now a fact, not a report.
- implementer: fixes null lookup in `cart.py`, runs targeted tests, replies with output.
- deployer: compose up, curls /health, sees new sha, logs to `.fleet/deploys.log`.
- tester: repro gone, e2e suite green, verdict PASS with output.
- Meanwhile every turn in every window, the hook re-injects that role's rules — at 300k tokens the tester still knows it never edits code.

**23:55 — task boundary, the reset moment.**

Coordinator ticks BUG-101 done in QUEUE.md, then as its **last action**:

```bash
~/fleet/bin/switch-task.sh BUG-102 "order confirmation email sent twice"
```

HANDOFF.md rewritten; implementer/deployer/tester each get `/clear` + "read your brief + HANDOFF, confirm task id" (waiting politely if one is mid-turn); coordinator's own reset fires when its turn ends. Four fresh contexts. BUG-101's dead ends, stack traces, and stale theories are gone — but its commits, deploy log, and QUEUE state survive, because they were never *in* context.

**02:10 — BUG-102 stalls.** Implementer hangs mid-investigation (busy indicator, no output). 02:15 watchdog cron notices frozen pane, sends Escape + "state your status, re-read HANDOFF, continue". Work resumes. No permission prompt can freeze anything — the allowlist rode in via `--settings` at launch.

**07:30 — you wake up.**

```bash
cd ~/src/webshop
cat .fleet/QUEUE.md        # BUG-101 ✓, BUG-102 ✓, TASK-103 in progress
cat .fleet/HANDOFF.md      # current: TASK-103
cat .fleet/deploys.log     # every deploy + verification result
git log --oneline          # the night's commits
tmux attach -t fleet-webshop   # full scrollback per role, nothing hidden
```

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
| `switch-task.sh <id> <summary>` | rewrite HANDOFF, reset peers, schedule coordinator self-reset |
| `fleet-reminder.sh` | UserPromptSubmit hook: cat role reminder every turn |
| `fleet-watchdog.sh` | cron: nudge hung panes (busy indicator + frozen output) |

## Overnight runs

1. `crontab -e`: `*/15 * * * * ~/fleet/bin/fleet-watchdog.sh >> ~/.cache/fleet-watchdog/log 2>&1`
2. Seed `.fleet/QUEUE.md` with the night's tasks; tell the coordinator to start.

The coordinator switches tasks itself: `switch-task.sh` is its last action per
task — it resets every peer so each task starts with fresh worker contexts.
The coordinator itself is the operator's long-form conversation and is NOT
reset by default; clear it yourself (`/clear`, or `reset-agent.sh` on its
window) when you want. For unattended overnight runs, tell the coordinator to
use `switch-task.sh --reset-coordinator` so its own context is recycled too.

## Design notes

- Coordination between agents = `SendMessage` (they're peer Claude Code
  sessions). Resets = tmux send-keys, because a session cannot clear a peer's
  context by message.
- Briefs are re-sent as one-liners pointing at files ("read X, confirm task
  id") — multi-line send-keys would submit early.
- Busy detection = "esc to interrupt" in the pane. Watchdog only nudges
  busy-but-frozen panes; idle waiting is normal and nudging it burns context.
