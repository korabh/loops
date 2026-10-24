---
name: loop-correct
description: Weekly loop. Finds mistakes agents keep repeating here and makes the most frequent one impossible.
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it. The method is the `correct` skill; this loop scopes it to the window and to one class per run.

## Steps

1. **Evidence** for the window: reverts, `fix:` commits that undo a recent `feat:`, commits whose message names a rule ("passes again", "no longer"), the loop briefs in `.claude/loops/log.md`, the notes in `.claude/loops/notes.md`, and review comments on merged PRs, in one call, leaving out bots' deploy and status comments: `gh pr list --state merged --search "merged:>=<date of at>" --limit 100 --json number,title,comments,reviews --jq '.[] | {number, title, comments: [.comments[] | .body], reviews: [.reviews[] | .body | select(. != "")]}'`.

2. **Classes.** Group the evidence into mistake classes per the `correct` skill. A class counts once it happened twice. Done: each class has at least two cited commits, comments or notes.

3. **Fix the most frequent class** at the highest level that works (architecture, then types, then a lint or test whose failure names the fix, then an `AGENTS.md` rule last), and prove the new check fails on one of the real past mistakes: check out its parent, apply the check, show red.

4. **Rule table.** Add or update the class's row in a "Rules and what enforces them" table at the end of the root `AGENTS.md`. A rule already in the table with nothing enforcing it is a repeat: enforce it in this same change.

5. **Ship.** Gate, then PR titled `chore(agents): <the mistake> can no longer <happen>`. Evidence: the past commit that now fails the check. Brief the classes left for later runs.
