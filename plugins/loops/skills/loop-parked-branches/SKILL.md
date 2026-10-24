---
name: loop-parked-branches
description: Weekly loop. Reports how far each parked wip/ branch has drifted from main, and what a rebase would cost.
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it. Parked branches belong to a person: this loop pushes nothing and moves no branch. It still writes its state file and appends its brief to the log, like every loop.

## Steps

1. **List** every `wip/*` branch, local and on `origin`. For each: `git rev-list --count <branch>..origin/main` (behind), `--count origin/main..<branch>` (ahead), and the date of its last commit.

2. **Trial rebase** in a throwaway worktree, detached at the branch tip: `git rebase origin/main`. Record the conflicting files, if any, then `git rebase --abort` and remove the worktree.

3. **Drift notes.** For each conflicting file, the main commits that touched it since the branch forked, one line each. A branch whose own commits main now contains in substance (`git cherry origin/main <branch>` marks them `-`) is flagged as a candidate to delete, for a person to decide.

   Done: every `wip/*` branch has behind, ahead, last-commit age, and clean-or-conflicting with its files.

4. **Brief**: one line per branch, `wip/<name>: <behind> behind, <ahead> ahead, <age>, rebases clean | conflicts in <n> files (<top 3>)`.
