---
name: loop-dead-code
title: Dead code sweeper
tagline: Removes exports and files nothing uses, one area at a time.
symbol: scissors
group: Tidy
every: 168
model: sonnet
worktree: true
description: Finds exports and files nothing imports and removes one area's worth, proved safe by the gate.
ships: one dead-code removal PR a week
---
1. **Find.** In a worktree per the conventions, run the stack's dead-code finder from the repo root (`bunx knip --reporter json` for JavaScript and TypeScript) and keep unused files and unused exports. Leave out generated code, files the framework loads by name (routes, pages, layouts, middleware, config files), backend functions a client calls by name, and anything a test imports on purpose.
   Done: a list of candidates by area.

2. **Choose.** Take one area, a route folder or one package, with the most candidates. For each candidate, search the repo for its name as a string too (`git grep -n "<name>"`), since dynamic imports and functions called by name do not show up as imports.
   Done: a batch where every item has no reference left.

3. **Remove.** Delete the batch, then gate. A red means something did use it: put that item back and gate again.
   Done: one PR, gate green.

4. **Result.** State: `areas` with this area added. Brief: what was removed, how many lines, and the PR.
