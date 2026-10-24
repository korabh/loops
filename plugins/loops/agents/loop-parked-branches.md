---
name: loop-parked-branches
description: Loop worker, dispatched by the loop runner.
model: sonnet
maxTurns: 200
disallowedTools: Artifact, EnterWorktree, Skill, mcp__*
omitClaudeMd: true
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/loop-parked-branches/SKILL.md` and follow it. Your prompt names the loop home and the loop conventions, and carries your state. Your result follows "Result" in `${CLAUDE_PLUGIN_ROOT}/conventions.md`.
