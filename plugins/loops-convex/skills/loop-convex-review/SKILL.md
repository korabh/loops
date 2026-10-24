---
name: loop-convex-review
description: Daily loop. Security and correctness review of every Convex function that changed on main.
disable-model-invocation: true
---

Read the loop conventions first, at the path your prompt names or `$(loop-runner kit)/conventions.md`; this loop runs on them. Read `convex/_generated/ai/guidelines.md` before judging any Convex code, when the repo has it (`npx convex ai-files install` writes it).

## Steps

1. **Window.** `git diff --name-only <sha>..origin/main -- convex ':!convex/_generated'`. Empty: return the state, brief one line, stop.

2. **Surface.** List every registered function (query, mutation, action, internal variants, `httpAction`) the window added or changed, with its file. This list is the loop's ledger.

3. **Review.** Over the ledger, apply the `convex-authz` scan (its four shapes) and the `convex-reviewer` checklist, and look for unbounded reads, the wall clock read inside a query, and functions missing `args` or `returns` validators.

4. **Prove each finding.** Read the handler and its callers until the finding has a concrete failure scenario: who calls it, with what, and what they get that they should not. A finding without one is dropped.

5. **Fix** each Critical or Important finding with a clear fix: first a `convex-test` case that shows the wrong caller succeeding (red), then the fix (green), in the style of the existing tests beside the function. Suggestions go to the brief only.

   Done: every function in the ledger carries a verdict: clean, fixed, or flagged with its failure scenario.

6. **Ship.** Gate, then PR titled `fix(convex): <what a caller can no longer do>`. Merge Danger names every public function whose behaviour changed.

7. **Brief.**
