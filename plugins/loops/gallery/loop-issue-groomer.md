---
name: loop-issue-groomer
title: Issue groomer
tagline: Keeps the issue list honest: closes what shipped, asks what's unclear.
symbol: tray.full
group: Ship
every: 168
model: sonnet
worktree: false
description: Goes through open issues untouched for 30 days, closes the ones already shipped and asks a specific question on the unclear ones.
ships: issue comments and closes, no code
---
1. **List.** Open issues with no activity in 30 days: `gh issue list --state open --limit 200 --json number,title,body,labels,updatedAt,assignees`. Leave out issues labelled `ready-for-agent` or `proposal`, and any issue a loop has claimed.
   Done: the list, oldest first, at most 15 for one run.

2. **Judge.** For each, find whether a merged PR already did it (`gh pr list --state merged --search "<words>"`, and the code itself), whether it is still true of the product today, and whether a builder could start from it as written.
   Done: each issue is shipped, still valid, or unclear.

3. **Act.** Shipped: comment which PR did it, then `gh issue close <n> --reason completed`. Unclear: comment one specific question that would make it buildable. Still valid and buildable: leave it, and name it in the brief as a candidate for `ready-for-agent`. Each comment follows "Comments on GitHub" in the conventions.
   Done: every issue on the list has its action.

4. **Result.** Brief: how many closed, asked and left, with the numbers, and a decision line for the ready candidates.
