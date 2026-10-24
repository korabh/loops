---
name: loop-pr-review
description: Loop worker, dispatched by the loop runner.
model: fable
maxTurns: 60
disallowedTools: Artifact, EnterWorktree, mcp__*
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/loop-pr-review/SKILL.md` and follow it. Your prompt names the loop home and the loop conventions, and carries your state. Your result follows "Result" in `${CLAUDE_PLUGIN_ROOT}/conventions.md`.
