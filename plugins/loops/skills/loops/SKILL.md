---
name: loops
description: How the loops work in this repo, and how to start, watch and stop the runner that schedules them. Use when asked about loops, the loop runner, its accounts, or adding a loop.
disable-model-invocation: true
---

A loop is a skill that does one recurring job in a repo: build the next ready issue, review new PR heads, keep main green. Each has an agent of the same name that sets its model, turn cap and tools. Loops run on one set of rules, `${CLAUDE_PLUGIN_ROOT}/conventions.md`: a loop locks itself, works in its own worktree, returns its state, brief and lesson as a result, and `loop-runner record` writes them into the **loop home**, the runner checkout at `<repo>/.claude/worktrees/loop-runner`. Panel reviewers run as `loops:loop-reviewer`, by `${CLAUDE_PLUGIN_ROOT}/panel.md`.

The runner is a background Claude Code session in the loop home running `/loop <every> /loops:runner`. Each tick it runs `loop-runner inputs` and the `loops:tick` workflow, which dispatches the loops that are due, most overdue first, four at a time, each in its own worktree, and skips a loop when nothing it watches changed.

## The repo's side

`.claude/loops.json`, committed, is what is particular to the repo (`/loops:setup` writes a first one):

- `name`, `about`: the repo's name and one line on its codebase;
- `timezone`: the zone loop `hours` are in;
- `setup`: `install` (run in every worktree a loop makes), `copy` (files copied from the main checkout into the runner's, such as `.env.local`), `env` (variables whose absence `loop-runner start` names, with what goes without them);
- `runner`: the runner session's `model` and `every`;
- `gate`: the steps `loop-gate` runs before every push, `{name, run}` with `BASE` set, `alone: true` for a step only one loop may run at a time;
- `ci`: the GitHub workflow and runner `label` whose red runs wake `loop-green-main` and `loop-pr-fix`;
- `monitors`: live commands whose lines wake a loop (`command`, `wakes`, `hours`, `cooldown`);
- `loops`: the cadence table, one entry per loop with `name`, `title`, `group`, `every` (hours), and optional `hours`, `alone`, `idleFor`, `ships`, and `plugin` for a loop that comes from a plugin.

`<home>/.claude/loops/project.md`, committed, is what every loop should know about the repo that no doc says: how its code is tested, where production is read, which paths need the adversarial review lens, its review bot, its fast-moving dependencies.

## The runner

From the repo, with the plugin enabled (`loop-runner` is on the PATH of every Claude Code session; outside one, run it from the plugin's `bin/` or through the Loops app):

```bash
loop-runner start    # runner worktree, install, copied files, a background session and a watchdog
loop-runner status   # session state and the last briefs
loop-runner attach   # open the session in this terminal
loop-runner stop     # refuses while a loop runs; --force to stop anyway
loop-runner resume   # restart a runner blocked on a usage limit that has reset
loop-runner pause <loop>... / unpause <loop>...
loop-runner account                                # this repo's rotation, own then shared, the active one starred
loop-runner account add [<config dir>] [--own]     # another subscription to fail over to, shared unless --own
loop-runner account use <config dir>|next [--force]
loop-runner account remove <config dir> [--sign-out]
loop-runner account own|share <config dir>
loop-runner account shared on|off                  # whether this repo falls back to shared accounts
```

`start` also registers the session with Remote Control as `loop-runner`. The watchdog sends a desktop notification when the session is blocked on a prompt, gone, or silent for 2.5 hours. When the session's last turn is a usage-limit error, the watchdog stops it, releases the runner's locks and starts it again on the next signed-in account, the repo's own accounts before the shared ones, and tries a limited account again an hour later.

Accounts live in `~/.loops/config.json`, one registry for every repo that runs loops: `shared` accounts any repo may use, and per repo its `own` accounts and whether it `useShared`. A usage limit is recorded per account in `~/.loops/limited/`, so a repo skips an account another repo just found limited. Give each added account a fresh config folder such as `~/.claude-loops-2`: `add` links the current account's settings, CLAUDE.md, skills, agents, commands and plugins into it, and copies its MCP servers and the trust of every registered repo. A recurring `/loop` expires after 7 days: `stop`, then `start`.

## Adding a loop

Run one by hand with `/loops:<loop>`, or a repo's own with `/<loop>`. To add, edit or remove a loop of the repo's own, pipe JSON to `loop-admin`, as the Loops app does: `{"action": "add" | "edit" | "remove", "name": "loop-…", …}`, with `title`, `group`, `every`, `hours`, `alone`, `model`, `worktree`, `description`, `ships` and, for add, `steps`. It writes the cadence entry, the skill and the agent together on a fresh branch off origin/main and opens the PR. For a plugin loop only the cadence entry changes. `"dry": true` prints the diff instead.

Ready-made loops live in the plugin's `gallery/`. `loop-gallery list` prints them as JSON with whether each already runs here; `loop-gallery add <name>` adds one through `loop-admin`, with optional JSON overrides on stdin.

No loop merges, deploys or writes to production; those come back in its brief.
