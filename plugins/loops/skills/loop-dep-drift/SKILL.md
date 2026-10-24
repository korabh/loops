---
name: loop-dep-drift
description: Weekly loop. Security advisories and fast-moving dependencies, checked against current docs on Context7.
disable-model-invocation: true
---

Read `${CLAUDE_PLUGIN_ROOT}/conventions.md` first; this loop runs on it.

## Steps

1. **Advisories.** The package manager's audit (`bun audit`, `npm audit`, `pnpm audit` or what `project.md` names). Each advisory with a patched version in range gets its own PR this run, before anything else.

2. **Drift.** The package manager's outdated list, run from the repo root and from each workspace. Keep the **fast movers**: the list in `project.md`, else the framework, runtime, backend, auth, AI SDK, styling, validation, test and build packages the repo depends on directly.

3. **Read the docs for each version gap.** For each fast mover behind latest: Context7 `resolve-library-id`, then `query-docs` for the changes between our version and latest (breaking changes, deprecations, renamed options). Then search the repo for each changed API. When a package ships its own upgrade guide, read it once bumped.

4. **Verdict per fast mover:**
   - _current_: nothing to do.
   - _bump_: no changed API touches our code → bump, install, gate.
   - _migrate_: changed APIs we use → no PR. The brief carries the migration notes and the count of call sites, ready for `to-spec`.

   Done: every fast mover and every advisory has a verdict.

5. **Ship.** Gate, then one PR per library bumped, titled `fix(deps): <library> <version>`. Evidence: the gate output on the new version, plus the Context7 note that says why nothing of ours broke.

6. **Brief.**
