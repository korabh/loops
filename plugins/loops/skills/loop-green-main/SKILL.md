---
name: loop-green-main
description: Daily loop, and woken by a red CI run on main. Keeps origin/main green on its gate and CI.
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it.

## Steps

1. **Window.** Commits `<sha>..origin/main`, plus failed Actions runs since `at`: `gh run list --branch main --status failure --json databaseId,name,createdAt,headSha`. Neither: return the state, brief one line, stop.

2. **Run the gate** in a fresh loop worktree at `origin/main`, against the window's start: `loop-gate <sha>`. For each failed run, `gh run view <id> --log-failed`.

3. **Name each red.** For every failing check, the commit in the window that turned it red (`git log -S`, or `git bisect run` over the window) and the root cause in one sentence. Infra reds (a missing secret, an expired token, a runner outage) go to the brief; they are not code. A root cause that is a fact about the repo, not a slip in one diff, is also a note.

4. **Fix code reds** at the root cause, smallest change that turns the check green. A red that is a behaviour bug gets a unit test, written with the `tdd` skill, that fails before the fix. A red `project.md` gives to another loop is that loop's; leave it.

   Done: every red is green in the worktree, or named in the brief with its cause and why the loop left it.

5. **Ship.** Gate, then PR titled `fix(<scope>): <what is green again>`. Evidence: the red output before, the green after.

6. **Brief.**
