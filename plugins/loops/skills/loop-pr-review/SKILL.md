---
name: loop-pr-review
description: Hourly loop. Reviews every open PR whose head has no review yet, and posts the verdict on the PR.
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it. It reviews; it never approves, requests changes, merges, or pushes to a PR's branch.

## Steps

1. **Frontier.** `gh pr list --state open --json number,title,body,headRefOid,isDraft,updatedAt,files`. Drop drafts, PRs not updated in 30 days, and PRs whose `headRefOid` equals the one recorded for them under `reviewed` in the loop's state file. Take the three lowest numbers; the rest wait for the next run. Empty: brief one line, stop. The runner reads this same frontier before it dispatches the loop (`idle` in `loop-runner`) and skips the run when it is empty, so a change to these filters changes it too.

2. **Check out** each PR at the `headRefOid` the frontier read, never `FETCH_HEAD`, which concurrent fetches overwrite: `git fetch origin pull/<n>/head`, then `git worktree add --detach <main>/.claude/worktrees/loop-pr-review-<n>-<stamp> <headRefOid>` (`<main>` and `<stamp>` per Worktree in the conventions). The fixed point is `origin/main`. Before adding yours, `git worktree remove --force` every `loop-pr-review-*` worktree already under `<main>/.claude/worktrees`: you hold the lock, so each one was left by a run that stopped before step 6.

3. **Panel.** First the code-review pass. When the repo runs a review bot on PRs, `project.md` names its login. Its findings on this head are its inline comments (`gh api repos/{owner}/{repo}/pulls/<n>/comments --jq '.[] | select(.commit_id == "<headRefOid>")'`), or else its summary comment (`gh api repos/{owner}/{repo}/issues/<n>/comments`) when it is newer than the head's commit date (`git log -1 --format=%cI <headRefOid>`). Those comments decide it. For each PR whose head has neither, run the `code-review` skill yourself with the Skill tool, args `high <n>`, without `--comment`; it forks its own reviewer. Run it one PR at a time: invocations started in one message cross-wire their targets.

   Then the panel, per PR, from the diff. Read it with `git diff origin/main...<headRefOid>` from your own checkout: a run the runner dispatched is isolated there, and Bash refuses a `cd` or `git -C` into the PR worktree, which exists for the panel. Each entry's `cwd` is that PR's worktree (lenses in `${CLAUDE_PLUGIN_ROOT}/panel.md`):
   - always: `quality`, `model` `opus`;
   - when the body says `Closes #<n>` or `Fixes #<n>`: `standards` and `spec`, `model` `opus`, the brief naming the issue as the spec;
   - when the diff touches authentication or authorization (the paths and guards `project.md` names, else code that reads an identity, a session or a permission, or a public endpoint): `adversarial` three times, `model` `fable`, `opus` and `sonnet`, the brief carrying the intent from the PR body;
   - for each part of the tree `project.md` gives a review lens, such as `convex-reviewer` for a backend folder, when the diff touches it outside tests: that lens, `model` `opus`.

   A **follow-up** is a PR whose `reviewed` head is an ancestor of `headRefOid` (`git merge-base --is-ancestor <old> <headRefOid>`): the whole diff was already reviewed at `<old>`. Its panel reviews the delta, `git diff <old>..<headRefOid>` over the files `git diff --name-only origin/main...<headRefOid>` lists. Apply the rules above to the delta, run `adversarial` once with `model` `opus`, and leave `spec` to the first review. Each brief names `<old>` as the base and lists the earlier verdict's Act on items to check. A head that does not descend from `<old>`, such as a rebase, gets the full panel.

   Return the panel with `resume`: each PR's number, `headRefOid`, worktree and code-review findings. Run by hand, spawn it and go on.

4. **Lead judgment**, in the run that holds the reports. Merge the code-review findings and the panel's reports into one verdict, with buckets from `interrogate`'s `references/lead-judgment.md`: **Act on**, **Consider**, **Noted**, **Dismissed**. A finding stays in Act on only with a concrete failure path: who calls what, with what, and what goes wrong. A bug the PR body declares stays in Act on when it has that path: declaring it does not fix it. On a follow-up, an earlier Act on item closes only when its fix holds at every caller of what it changed (grep them across the repo). A finding an earlier verdict on this PR already bucketed keeps that bucket unless the delta or new evidence changes its failure path. Five Act on items at most; past that, the filtering was too loose.

   Done: every panel finding sits in exactly one bucket, with a one-line reason.

5. **Post.** Re-read `gh pr view <n> --json state,headRefOid` first. Merged or closed: post nothing, brief the Act on items as follow-ups for `main`. Head moved: post nothing; the next run reviews the new head.

   Otherwise post one review, `event: "COMMENT"`, through `gh api repos/{owner}/{repo}/pulls/<n>/reviews --method POST --input <mktemp json>`:
   - `commit_id`: the reviewed `headRefOid`;
   - `body`: the verdict line first (`ready to merge`, `merge after Act on`, or `needs rework`), then the buckets, then the panel: each reviewer whose report this run holds, by lens and model, and the code-review pass by its source. A lens that did not run is not named;
   - `comments`: one inline comment per Act on and Consider finding that the workflow or an earlier verdict has not already threaded on that line (`path`, `line`, `side: "RIGHT"`). A threaded finding goes inline again only when new evidence changes the answer the author gave. Every `line` must sit inside the diff's hunks (`git diff -U0 origin/main...<headRefOid> -- <path>`), or GitHub refuses the whole review. Anchor a finding on an unchanged line to the nearest added line and name the real line in its text. A finding with no line (commit author, PR body) stays in the body. Noted and Dismissed stay in the body.

   Return `state.reviewed` as `{"<n>": "<headRefOid>"}` for the PRs this run posted on; the record deep-merges it into the stored map. Return a note for each Act on item a fact about the repo would have prevented.

6. **Clean up** each worktree. Brief: one line per PR, `#<n> <verdict>, <k> act on`.
