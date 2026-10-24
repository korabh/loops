---
name: loop-convex-review
description: Loop worker, dispatched by the loop runner.
model: opus
maxTurns: 200
isolation: worktree
disallowedTools: Artifact, EnterWorktree, Skill, mcp__*
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/loop-convex-review/SKILL.md` and follow it. Your prompt names the loop home and the loop conventions, and carries your state. Your result follows "Result" in those conventions.
