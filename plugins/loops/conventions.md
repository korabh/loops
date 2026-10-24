# Loop conventions

Every loop skill runs on these; below, `<loop>` is the skill's name and `<name>` the same without `loop-`. A skill a loop names is loaded with the Skill tool, or read from its folder (`.claude/skills/<skill>/`, `~/.claude/skills/<skill>/` or a plugin's) when the loop's agent has no Skill tool or the tool cannot load it. Before editing a skill, an agent, `AGENTS.md` or `CLAUDE.md`, read the `writing-for-agents` skill when the repo has it. A loop runs unattended: nobody answers mid-run, so anything that needs a person goes into the brief, prepared and decision-ready.

The **loop home** is the runner checkout, `loop-runner home`, whoever runs the loop. Every `.claude/loops/` path in a loop skill, state and log included, is under the loop home, never under a worktree. `loop-runner kit` is where the loops plugin lives; these conventions and `panel.md` are there.

What is particular to this repo is in `.claude/loops.json` (its setup, gate and CI) and, when it exists, `<home>/.claude/loops/project.md`: how its code is tested, where production is read, and anything else every loop should know. Read both at Start.

## Start

1. `loop-runner lock <loop>`. When it says the loop is busy, another run holds it, the runner's or a person's: return `busy: true` with that line as the brief, and stop; run by hand, just stop. Nothing is recorded for a busy run, so the lock stays with its holder.
2. Read the last 40 lines of `<home>/.claude/loops/lessons/<loop>.md` and of `<home>/.claude/loops/notes.md`; a missing file is an empty one. Read `<home>/.claude/loops/project.md` when it exists.
3. `git fetch origin`.

## Window

A loop's last pass lives in its own file, `<home>/.claude/loops/state/<loop>.json`; the runner hands its contents to the loop in the prompt, and a run by hand reads the file:

```json
{ "at": "2026-10-10T07:00:00Z", "sha": "95f26bff" }
```

The window is `<sha>..origin/main`; with no state, the last 7 days of `origin/main`. `at` is when that run started. `watched`, when present, is the runner's fingerprint of what the loop watches, which the runner keeps itself.

## Result

A loop writes nothing under the loop home: `loop-runner record` writes its result there and releases its lock. The result:

- `state`: `sha` (`git rev-parse --short origin/main`, as this run read it) and every key the loop keeps that changed. The record merges it into the stored state and stamps `at`; a key set to `null` is removed;
- `brief`: the brief below;
- `lesson`: one line the next run should know that the skill does not say (a signature that is always transient, a check that is always noisy), or empty;
- `note`: what every loop should know, per Notes below, or empty;
- `panel` and `resume`: only to ask for a review panel, per Panel below;
- `workflow` (`name` and `args`) and `resume`: only for a loop marked `alone` in `.claude/loops.json`, to ask the runner to run a workflow, per that loop's skill;
- `busy`: only per Start.

Dispatched by the runner, return it; the runner records it. Run by hand, pipe `{"loop": "<loop>", "result": <the result>}` to `loop-runner record`, a run that stops early included.

## Notes

The notes are what the loops know about this repo that no doc says: build quirks, verification gotchas, findings reviews keep raising. Every loop reads the newest at Start, before it writes code or judges a diff.

A run that learns such a fact, one that would have saved another loop a red, a revision round or an Act on item, returns it in `note`, one line per fact: `[<area>] <the fact, stated so the next builder gets it right>`. A fact only your own loop needs is a `lesson` instead.

## Worktree

A loop that writes code works in a worktree of its own, never in the main checkout or the loop home: other sessions edit the first, and the runner reads the second. Every worktree shares one set of refs, so another run's fetch can move `origin/main` mid-run: pin the base when you branch, and diff, reset and gate against the pin.

- **Dispatched by the runner**, you start in a worktree Claude Code made: `git rev-parse --show-toplevel` is not the loop home. Copy each file `setup.copy` in `.claude/loops.json` names from the loop home when it is missing, then `git switch -c loop/<name>/<stamp> origin/main`.
- **Run by hand**, whenever the toplevel is the loop home, and for a loop that asks for a panel: `git worktree add -b loop/<name>/<stamp> <main>/.claude/worktrees/loop-<name>-<stamp> origin/main`, with `<main>` the main checkout (`git rev-parse --path-format=absolute --git-common-dir` without `/.git`). Work there by absolute path, and `git worktree remove` it when the run ends.

`<stamp>` is `date -u +%Y%m%d-%H%M`, so no two runs share a branch or a directory; name every other worktree a loop adds, a PR checkout or a probe, with it too. Then `base=$(git rev-parse HEAD)` and run `setup.install` from `.claude/loops.json`. To take newer main, `git fetch origin`, `new=$(git rev-parse origin/main)`, `git rebase "$new"`, then `base=$new` and install again. Scratch files go in `mktemp -d`, never a fixed `/tmp` name another run may share.

One open PR per loop, unless its skill names its own branches. When `gh pr list --state open --json number,headRefName,url --jq '.[] | select(.headRefName | startswith("loop/<name>/"))'` returns one, switch to that branch instead and push onto it.

On macOS the shell is zsh with BSD tools: `sed -i ''`, `mktemp` wants trailing `XXXXXX`, there is no `PIPESTATUS`, and `grep` may be ugrep, so check an empty grep against a line you know matches.

Dispatched by the runner, keep each Bash call to plain commands joined by `&&`, `;` or `|`: one call per issue or file in place of a `for` loop, no `$(…)` beside git, and git aimed at your own worktree only. Bash refuses any command it cannot prove keeps git there, a `cd` or `git -C` into another worktree included, and each refusal costs a retry.

## Tests

A loop that writes a test uses the `tdd` skill. Its seams are agreed in advance, since nobody answers mid-run: the public interface of the code under test, a module's exports or whatever `project.md` names for this repo.

## Gate

Before every push, from the worktree: `loop-gate "$base"`. It runs the `gate` steps in `.claude/loops.json` with `BASE` set to the base, a step marked `alone` one loop at a time; every step runs even after a red, and it ends by listing each failing step's errors. The gate goes green or nothing is pushed. A check already red on `origin/main` does not block, as long as the branch adds no failure to it: name it in the brief, and `loop-green-main` owns it. A red you cannot fix inside the loop's scope: drop the change and name the red in the brief.

## Panel

A review that needs independent reviewers is a panel; its lenses are in `panel.md` in the kit. Dispatched by the runner, a loop cannot spawn agents, so it asks: commit its work, and return `panel`, one entry per reviewer with `lens`, `cwd` (an absolute path in a worktree the loop added), `brief` and an optional `model`, and `resume`, where it stopped and what is left, with `state` so far and a one-line `brief`. The runner runs the panel, then dispatches the loop again with `resume` and every report; that run skips Start, since the first run holds the lock, carries on in the worktrees `resume` names, and returns the final result. Run by hand, spawn one `loops:loop-reviewer` agent per entry, all at once, with the prompt `panel.md` gives.

## Pull request

- Commits in the house style (`git log --oneline -20`). Attribution follows the repo's `AGENTS.md` or `CLAUDE.md`.
- Body: the `pr` skill's template when the repo has it (Summary / Evidence / Merge Danger), with Door and Blast Radius from the `blast-radius` skill. Evidence is the gate output and, for a fix, the test that went red before the change and green after.
- Write the body to a fresh `mktemp` file, never a fixed path another loop's agent may write too, then `gh pr create --base main --head <your branch> --body-file <that file>`.
- A person merges. The loop only ever pushes its own `loop/<name>/*` branch.

## Production

Read-only: the production reads `project.md` names, and GitHub API reads. A deploy, migration, data change or environment change goes into the brief as the exact command for a person to run.

## Brief

Every run ends with a brief, which the record appends with a UTC timestamp to `<home>/.claude/loops/log.md`:

- Nothing found: one line, `<name>: <what was checked> clean since <sha>`.
- Otherwise, five lines at most: what was found, what was done, the PR link, and each decision that needs a person.

Each decision for a person in a brief carries a deep link that opens Claude Code in the repo with the next step typed in: `claude-cli://open?repo=<owner/repo>&q=<url-encoded prompt>`, with `<owner/repo>` from `gh repo view --json nameWithOwner --jq .nameWithOwner`, for example `q=review%20PR%20%2319`. Deep links stay in briefs: GitHub and issue trackers do not make `claude-cli://` clickable, so in a comment it shows as a raw URL.

## Comments on GitHub

A comment on an issue or PR is read by whoever opens it next. Write whole sentences, and link the way GitHub renders: `#35`, a full https URL, or `[text](https://…)`. A claim says what is being built and on which branch; a PR comment says which PR closes the issue and where to start reviewing it.
