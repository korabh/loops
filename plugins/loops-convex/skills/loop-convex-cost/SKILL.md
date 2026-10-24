---
name: loop-convex-cost
description: Weekly loop. Production read limits, write contention and spend drivers from Convex insights, root-caused in code.
disable-model-invocation: true
---

Read the loop conventions first, at the path your prompt names or `$(loop-runner kit)/conventions.md`; this loop runs on them. Production is read-only here.

## Steps

1. **Insights.** `npx convex insights --prod --details`: the last 72 hours of read-limit hits, read thresholds approached, and OCC retries and failures, per function.

2. **Root-cause** each insight in code, following the `convex-advisor` and `convex-cost` skills: the query or mutation, the table it reads, the index it uses or misses, and the read it does that it does not need. Every number passes the `principle-explain-the-number` skill before it is reported.

   Done: every insight has a function, a cause, and a cheapest fix, or is marked transient with the evidence.

3. **Compare** with last week's list, kept under `insights` in the loop's state file. New insights and ones that grew come first.

4. **Fix** the insight with the largest cost or the only hard limit hit, when the fix is in code (an index, a bounded read, a split document): `convex-test` case first, then the fix, gate, PR titled `perf(convex): <function> reads <what> instead of <what>`. An index that needs a staged rollout, or a migration, goes into the brief with its exact steps.

5. **Store** this week's list. Brief.
