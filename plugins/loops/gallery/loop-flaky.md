---
name: loop-flaky
title: Flaky test hunter
tagline: Catches the tests that fail and then pass on a retry, and fixes why.
symbol: arrow.triangle.2.circlepath
group: Guard
every: 24
model: opus
worktree: true
description: Finds tests that fail and then pass without a code change, and fixes the cause or quarantines the test with an issue.
ships: a flaky-test fix PR when one turns up
---
1. **Find.** In the window, list runs of the `ci` workflow in `.claude/loops.json` that went red and then green on the same commit (`gh run list --workflow <it> --limit 100 --json databaseId,headSha,conclusion,attempt,createdAt`, then `gh run view <id> --log-failed` for the red ones), and the flake reruns the loop gate reported in `.claude/loops/log.md` and `.claude/loops/notes.md`. Name each flaky test by file and test name.
   Done: a list of flaky tests with how often each failed, or none.

2. **Reproduce.** Take the test that failed most. In a worktree per the conventions, run it alone in a loop (the test runner's single-test command, such as `bunx vitest run <file> -t "<name>"`, twenty times) until it fails, and read why: time or timezone, order between tests, shared state, an unawaited promise, a race on a real timer.
   Done: the failing run's output, or twenty green runs.

3. **Fix.** Fix the cause in the test or the code with the `tdd` skill, and show it green twenty times in a row. When the cause is outside the loop's reach, skip the test with `.skip` and a reason, and file an issue naming the test, the failure and the runs it broke.
   Done: one PR, gate green, or the issue and the skipped test in one PR.

4. **Result.** State: `seen` with each test named and its count. Brief: the flaky tests found, what was fixed or quarantined, and the PR.
