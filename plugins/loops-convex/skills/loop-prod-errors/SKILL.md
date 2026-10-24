---
name: loop-prod-errors
description: Hourly loop in working hours. Turns new production errors into reproduced, fixed, unmerged PRs.
disable-model-invocation: true
---

Read the loop conventions first, at the path your prompt names or `$(loop-runner kit)/conventions.md`; this loop runs on them. Production is read-only here; the `convex-self-heal` skill is the reference for triage and certification.

## Steps

1. **Collect.** Errors since `at`:
   - Convex: the runner's `prod-events` monitor (an entry in `monitors` of `.claude/loops.json`) appends every failed execution to `<home>/.claude/loops/prod-events.jsonl` as `{ts, fn, type, error}`; take the lines whose `ts` is after `at`. For the context around a signature (log lines, caller), `timeout 45 npx convex logs --prod --history 2000 --jsonl`: it streams until killed, so exit 124 is expected, and it holds only the last ~1,000 executions, so state the span it covered. When the file's first line is after `at`, the runner was down for the gap: say so.
   - Sentry, when `SENTRY_AUTH_TOKEN`, `SENTRY_ORG` and `SENTRY_PROJECT` are set: `curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" "${SENTRY_URL:-https://sentry.io}/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=is:unresolved&statsPeriod=24h"`. Unset, skip it.

   Group into **signatures**: function or route, plus the error message with ids and timestamps stripped.

2. **Drop known signatures.** The loop's state file keeps `handled`: signature → PR URL. A signature already handled whose PR is still open is skipped. One whose PR merged and that still fires is a **recurrence**: brief it with the PR.

3. **Classify** each new signature: _transient_ (a one-off network or provider blip), _config_ (a missing env var, secret or domain), or _code_. Transient and config go to the brief; config with the exact command a person runs.

4. **Fix code signatures** with the `tdd` skill. Reproduce first: a `convex-test` or vitest case that throws the same error from the same input (red). Then fix the root cause (green). A signature you cannot reproduce goes to the brief with what you tried.

   Done: every signature carries a verdict: transient, config, fixed in a PR, or not reproduced.

5. **Ship.** Gate, then one PR per signature, titled `fix(<scope>): <what no longer fails>`. Record each in `handled`.

6. **Brief.**
