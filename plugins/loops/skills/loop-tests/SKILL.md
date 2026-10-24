---
name: loop-tests
description: Daily loop. Reverts each behaviour change merged to main and pins the ones no test catches with a test written the tdd way.
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it. Every test here is written with the `tdd` skill. The loop adds and rewrites tests; production code stays as main has it.

## Steps

1. **Window.** Non-merge commits in the window that change behaviour: source files (the roots `project.md` names, else every source file), leaving out tests and generated code. Add the `gaps` the state file carried from the last run. Neither: brief one line, stop.

2. **Probe** each change in a loop worktree at `origin/main`: reverse that commit's hunks alone (`git diff <c>^ <c> -- <files> | git apply -R`), run the tests that reach the changed code, then `git checkout -- .`.
   - The tests that reach it are the test files importing the module, plus any `project.md` says reach code another way. Run them from the workspace that owns them.
   - Some test goes red: **caught**. All green: a **gap**. The reverse no longer applies because later commits rewrote the code: **superseded**, dropped.

   Done: every change in the window is caught, a gap, or superseded.

3. **Audit** the test files the window added or changed against the `tdd` skill's anti-patterns. Each implementation-coupled or tautological test is **weak**, named with its anti-pattern.

   Done: every test file the window touched is clean or has its weak tests named.

4. **Pin** five at most, gaps with the most changed lines first, then weak tests, one at a time with the `tdd` skill:
   - A gap gets a test at the changed code's seam that goes red with the commit's hunks reversed and green on `origin/main`.
   - A weak test is rewritten at the same seam, held to the same red and green.
   - A test written from the commit's intent that fails on `origin/main` has found a bug: leave it out of the PR and brief it as a decision, with the test and its failure.

   The rest go to `gaps` in the state file for the next run.

   Done: each pinned item has its red output, hunks reversed, and its green output, on main, in your working notes.

5. **Ship.** Gate, then PR titled `test(<scope>): <the behaviour a test now catches>`. Evidence: per test, the reversed hunk and the red it produced.

6. **Brief:** caught, pinned, carried, and any bug found.
