---
name: loop-pr-fix
description: Loop worker, dispatched by the loop runner.
model: opus
maxTurns: 140
isolation: worktree
disallowedTools: Artifact, EnterWorktree, Skill, mcp__*
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/loop-pr-fix/SKILL.md` and follow it. Your prompt names the loop home and the loop conventions, and carries your state. Your result follows "Result" in `${CLAUDE_PLUGIN_ROOT}/conventions.md`.
