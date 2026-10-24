---
name: runner
description: One tick of the loop runner, run by `/loop` in the runner checkout that `loop-runner start` makes. Not for running by hand elsewhere.
disable-model-invocation: true
---

You are the loop runner. Each tick, run the loops that are due, then stop. You dispatch; the loops do the work.

1. **Where.** `git rev-parse --show-toplevel` must end in `.claude/worktrees/loop-runner`. Anywhere else, reply with `loop-runner start` and do nothing more: the main checkout is shared with other sessions.

2. **Refresh.** `git fetch origin`. When `git status --porcelain --untracked-files=no` is empty, `git switch --detach origin/main`, so this tick reads the merged loop skills; untracked run files never hold the checkout back.

3. **Inputs.** `loop-runner inputs` prints `{ home, kit, now, hour, loops, states, busy, watched, idle }`; `kit` is where the loops plugin lives, `loops` the cadence table in `.claude/loops.json`, `hour` the hour in its `timezone`, `busy` every loop a run still holds, from this runner or a person's session, `watched` a fingerprint of what a loop watches, so far the issue queue's issues and PRs and the PR fixer's work, and `idle` every loop whose frontier the runner read and found empty, so far the PR reviewer when every open PR it would review is already reviewed at its head, and the PR fixer when no `loop/` PR has a red check or an Act on verdict left on its head. Add `events`: the lines each monitor below reported since the last tick, keyed by the loop it wakes (a monitor's `wakes`, a CI red's `loop` field), or `{}`.

4. **Run the saved workflow `loops:tick`** with that object as `args`, exactly as printed plus `events`. It reads the cadences from `loops`, picks what is due, skips a loop in `idle` (for at most `idleFor` hours after its last run when the loop sets one, as the PR fixer does) and one whose `watched` fingerprint matches the one its state recorded in the last day, and dispatches each loop to its own agent in its own worktree, with the loop's review panel, or the workflow runs a loop marked `alone` asks for. Without the Workflow tool, do the same by hand: the cadences are in `.claude/loops.json`, the rules in `<kit>/workflows/tick.js`, and a loop's agent type is `<plugin>:<name>` when its entry names a `plugin`, else its name.

5. **Monitors, live.** For each entry in `monitors` of `.claude/loops.json`, keep exactly one Monitor armed, described as its `description`, with the longest timeout it allows, running its `command`. Each line it prints is an event for the loop it `wakes`. A line with a `cli` key means the stream itself failed: say so in the report and re-arm next tick. On an event inside the entry's `hours`, with that loop not busy and its last run over `cooldown` minutes ago, run `loops:tick` at once with the event lines as `events`. Otherwise keep the lines for the next tick. When a monitor expires, arm it again.

6. **CI reds, live.** When `.claude/loops.json` names a `ci` workflow, keep one more Monitor armed, described `ci reds`, with the longest timeout it allows: `loop-runner ci-events`. Each line is a red run of that workflow, on the runners its `label` names, for `loop-green-main` on `main` or for `loop-pr-fix` on a `loop/` PR. On a line, run `loops:tick` at once with fresh inputs and the line as its loop's event; the tick still skips a loop that is busy, paused or backing off. When the monitor expires, arm it again.

7. **Record.** `loop-runner record <the workflow's output file>`, the path its completion notice names. It merges each loop's state, appends its brief, lesson and notes, and releases its lock; a loop that returned no result, stopped at its agent's `maxTurns` or failed, keeps its window and counts a miss, and the tick backs it off two hours, doubling with each miss in a row up to a day or its own cadence; the command says so: put that in the report.

8. **Report** each brief, one block per loop, and nothing else. A brief that names a PR or a decision for a person: send it as a push notification too.
