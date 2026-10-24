---
name: loop-issue-queue
description: Hourly loop. Takes the next ready-for-agent GitHub issue to a reviewed PR, one issue per run.
argument-hint: "[issue number]"
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it. When the repo describes its issue tracker, as `docs/agents/issue-tracker.md` does, read that too.

## Steps

1. **Frontier.** `gh issue list --state open --label ready-for-agent --json number,title,body,assignees,comments`. Drop issues with an open blocker (`gh api repos/{owner}/{repo}/issues/<n> --jq .issue_dependencies_summary.blocked_by`) or with an open PR that references them. Drop assigned issues too, except a **stalled claim**: its newest claim comment is the issue-queue loop's or routine's, no person has commented since, and its run is gone. A local run is gone whenever you hold the lock, since every local run takes it; a routine run is gone once its claim is 3 hours old. Take a stalled claim first, else the lowest number. Started with an issue number, take that issue, after the same drops. Empty frontier: brief one line, stop.

   A stalled claim skips steps 2 to 4. Its branch is the newest `loop/issue-queue/<n>-*` that `git branch --list 'loop/issue-queue/<n>-*' -v` or `git ls-remote origin 'refs/heads/loop/issue-queue/<n>-*'` shows. Cut `loop/issue-queue/<n>-<slug>-<stamp>` from its tip, or from origin/main when it has no commits past main, and comment on the issue that the loop resumes it on that branch. Its commits are build already done: go on at step 5. Edits its run never committed stay in its worktree, untouched.

2. **Ownership.** Re-read the issue's comments. A person claiming the fix, or a plan addressed to someone else, means stop: the loop does not race a person.

3. **Existing fix.** An open PR or a merged commit that plausibly resolves the issue switches the run to [verify-existing-fix.md](verify-existing-fix.md). No competing PR.

4. **Claim.** `gh issue edit <n> --add-assignee @me` and a comment naming the loop. Then re-read the comments: an earlier claim from another run, local or routine, has the issue, so delete your comment and stop.

5. **Qualify.** The issue is buildable without a question: its acceptance criteria can each be checked by a test or a command. Otherwise comment the exact questions, unassign, remove `ready-for-agent`, brief, stop.

6. **Build.**
   - An issue with sub-issues is a spec with tickets: run the `implement-spec` skill on it, the integration branch named `loop/issue-queue/<n>-<slug>`.
   - A single ticket: on that branch, in the worktree you start in when the runner dispatches you, since your Bash refuses git in any other and a worktree with commits outlives your run; run by hand, in one you add (Worktree in the conventions). The `tdd` skill at the seams the issue names, typecheck and single test files as you go. Then the `code-review` skill on the branch with the Skill tool, which forks its own reviewer, and a panel of `standards` and `spec`, `model` `opus`, the issue as its spec and that worktree as its `cwd` (Panel in the conventions). Fix what they raise in the resumed run.

   Done: every acceptance criterion is ticked by a passing test or a command whose output goes in the Evidence.

7. **Ship.** Gate, then PR titled in the house style with `Closes #<n>` in the body. Evidence maps each acceptance criterion to its proof. Comment the PR link on the issue.

8. **Brief.**
