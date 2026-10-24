---
name: loop-pr-fix
description: Hourly loop. Fixes red checks and the Act on items loop-pr-review raised on loop PRs, on their own branches.
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it. It only ever pushes to a `loop/*` branch. A PR a person opened is theirs: the review comment is all this system gives it.

## Steps

1. **Frontier.** Open PRs whose head branch starts with `loop/`, and on each PR's current `headRefOid`, two kinds of work:
   - **Act on items**: the newest `loop-pr-review` verdict, the review whose body opens with the verdict line, has Act on items, was given on this head, and has no answer from this loop yet, the `fixed in` / `answered:` lines step 5 posts. A PR pushed since its review waits for the next one.
   - **Red checks**: `gh pr checks <n> --json name,bucket,link,workflow` has a check in the `fail` bucket. A check also red on `origin/main`'s head (`gh api repos/{owner}/{repo}/commits/<sha>/check-runs` and `.../status`) belongs to `loop-green-main`, and a head recorded under `briefed[<n>]` in the state file has had its reds briefed; drop both.

   Keep the PRs with either kind. A PR this loop has pushed to twice already (`rounds[<n>]`) is out: brief it as needing a person. Empty: brief one line, stop.

2. **Check out** the PR's branch in your worktree: `git fetch origin <headRefName>`, `git switch -C <headRefName> origin/<headRefName>`, then `setup.install` from `.claude/loops.json`.

3. **Diagnose** each red check and reproduce it in the worktree:
   - an Actions check: `gh run view <run id from its link> --log-failed`, then the failing command its job runs in `.github/workflows/`;
   - a deployment-preview check (Vercel, Netlify and the like): its build command, run where `project.md` says, with the env it names; read the build log the way `project.md` names.

   Name the root cause in one sentence. An infra red (a missing secret, an expired token, a runner or service outage) is not code: it goes to the brief. A red the gate passed on is a note: the check catches something the gate does not run.

   Done: every red check is reproduced with its root cause named, or named infra.

4. **Fix** each code red and each Act on item at its root cause, with the smallest change. A red that is a behaviour bug gets a test, written with the `tdd` skill, that fails before the fix; an Act on item gets the test the finding asks for when it names one. A finding you can show is wrong gets a reply on its inline comment with the evidence, not a code change.

   Done: every code red passes its reproducing command in the worktree, and every Act on item is fixed in a commit or answered with evidence.

5. **Ship.** Gate, then push to the same branch, never force. Reply on the review with one line per Act on item, `fixed in <sha>` or `answered: <why>`, and comment on the PR one line per red check, `<check>: fixed in <sha>` or `<check>: infra, <cause>`. Record `rounds[<n>] += 1`. A run that pushes nothing posts its lines all the same and records `briefed[<n>] = <headRefOid>`, so its reds wait for a new head. The next `loop-pr-review` run reviews the new head.

6. **Brief.** Each infra red is a decision for a person: the check, its cause, and the fix to make.
