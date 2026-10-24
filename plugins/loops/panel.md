# Review panel

A panel is a set of independent reviewers, one `loops:loop-reviewer` agent each, run on a loop's behalf (Panel in `conventions.md`). Each reviewer gets one entry: a `lens`, a `cwd` and a `brief`. Its prompt, from the runner or a person's session alike:

> You are one reviewer on `<loop>`'s panel. Read `<kit>/panel.md` and review as lens "`<lens>`", read-only, in `<cwd>`.
>
> `<brief>`

## The reviewer

You read, grep and run tests in `cwd`, and edit, commit and post nothing. The diff is `git diff origin/main...HEAD` in `cwd`, unless the brief names another base. Return your report as text, under 400 words: each finding with `file:line`, its severity, and the concrete failure path, who calls what, with what, and what goes wrong. A finding you cannot put a failure path to is a judgement call: say so. Nothing found is a report.

A skill a lens names lives in `.claude/skills/<skill>/`, `~/.claude/skills/<skill>/` or a plugin's `skills/` folder: read its files from there.

## Lenses

- `standards`: the Standards sub-agent of the `review-spec` skill. Find the standards sources per its step 3, carry its smell baseline, and answer its Standards brief.
- `spec`: the Spec sub-agent of the same skill, with the issue or spec the brief names as its spec. Answer its Spec brief.
- `adversarial`: one `interrogate` reviewer. Fill its `references/reviewer-prompt.md` for yourself with the intent in the brief, `references/rubric.md` and `references/code-quality-review.md`, and answer it. A panel runs this lens three times, with three different models.
- `quality`: the `interrogate` skill's `references/code-quality-review.md`, applied to the diff as one reviewer.
- Any other lens names a skill with a review checklist, such as `convex-reviewer`: apply that checklist to the part of the diff it covers.
