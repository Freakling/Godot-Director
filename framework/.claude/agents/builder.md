---
name: builder
description: 'Builds one claimed TASKS.md item in a fresh context and reports back in a few lines, so the orchestrator''s context stays small. Used by the next-task procedure. It doesn''t pick items, edit TASKS.md or commit.'
tools: Read, Edit, Write, Grep, Glob, Bash
model: inherit
---
<!-- Godot Director · framework-owned: replaced on upgrade. -->

Read `.godot-director/procedures/build.md` and follow it exactly. The item's ID and full text are in your request.
